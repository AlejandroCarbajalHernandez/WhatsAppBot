import os, json, boto3, requests
from datetime import datetime

# Clientes
bedrock = boto3.client(service_name='bedrock-agent-runtime', region_name='us-east-1')
dynamodb = boto3.resource('dynamodb')
history_table = dynamodb.Table(os.environ['TABLE_NAME'])

def lambda_handler(event, context):
    # --- Validación de Webhook de Meta (GET) ---
    if event.get('httpMethod') == 'GET':
        params = event.get('queryStringParameters', {})
        if params.get('hub.verify_token') == os.environ.get('VERIFY_TOKEN'):
            return {'statusCode': 200, 'body': params.get('hub.challenge')}
        return {'statusCode': 403}

    try:
        body = json.loads(event.get('body', '{}'))
        value = body.get('entry', [{}])[0].get('changes', [{}])[0].get('value', {})
        
        if 'messages' not in value:
            return {'statusCode': 200}

        user_phone = value['messages'][0]['from']
        user_text = value['messages'][0]['text']['body']

        # 1. Guardar mensaje del usuario en DynamoDB
        history_table.put_item(Item={
            'SessionId': user_phone,
            'Timestamp': datetime.utcnow().isoformat(),
            'Role': 'user',
            'Text': user_text
        })

        # 2. Llamada al Agente usando TSTALIASID
        # Importante: Habilitamos enableTrace para ver qué pasa si falla
        response = bedrock.invoke_agent(
            agentId=os.environ['AGENT_ID'],
            agentAliasId=['AGENT_ALIAS_ID'],
            sessionId=user_phone,
            inputText=user_text,
            enableTrace=True, 
            sessionState={'sessionAttributes': {'user_phone': user_phone}}
        )

        ai_reply = ""
        
        # 3. Procesar el streaming de respuesta
        for event in response.get('completion', []):
            # Si el agente genera texto para el usuario
            if 'chunk' in event:
                chunk_text = event['chunk']['bytes'].decode('utf-8')
                # Filtramos para que no se escape el nombre de la función en el chat
                if "getAvailability" not in chunk_text and "bookAppointment" not in chunk_text:
                    ai_reply += chunk_text
            
            # Si el agente está pensando o llamando a la Lambda (Trace)
            elif 'trace' in event:
                # Esto se verá en los logs de CloudWatch de ESTA Lambda
                # Muy útil para debuguear por qué no se llama a la otra Lambda
                print(f"DEBUG TRACE: {json.dumps(event['trace'])}")

        # 4. Solo procedemos si el Agente entregó una respuesta final
        if ai_reply.strip():
            # Guardar respuesta de la IA
            history_table.put_item(Item={
                'SessionId': user_phone,
                'Timestamp': datetime.utcnow().isoformat(),
                'Role': 'assistant',
                'Text': ai_reply
            })

            # Enviar a WhatsApp
            send_whatsapp(user_phone, ai_reply)
        else:
            print("El agente no generó respuesta de texto (posible espera de herramienta o error).")

    except Exception as e:
        print(f"Error General: {str(e)}")
    
    return {'statusCode': 200}

def send_whatsapp(phone, text):
    # Asegúrate de tener estas variables en tu Lambda
    token = os.environ.get('FB_TOKEN')
    phone_id = os.environ.get('PHONE_ID')
    url = f"https://graph.facebook.com/v18.0/{phone_id}/messages"
    
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    payload = {
        "messaging_product": "whatsapp",
        "to": phone,
        "type": "text",
        "text": {"body": text}
    }
    
    r = requests.post(url, json=payload, headers=headers)
    print(f"WhatsApp Status: {r.status_code}, Response: {r.text}")