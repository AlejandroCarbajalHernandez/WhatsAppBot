import json
import os
import boto3
import requests

# Inicializamos el cliente de Bedrock
bedrock = boto3.client(service_name='bedrock-runtime', region_name='us-east-1')

# Leer variables de entorno inyectadas por Terraform
WHATSAPP_TOKEN = os.environ.get('WHATSAPP_TOKEN')
PHONE_NUMBER_ID = os.environ.get('PHONE_NUMBER_ID')
VERIFY_TOKEN = os.environ.get('VERIFY_TOKEN')
API_VERSION = os.environ.get('API_VERSION', 'v24.0') # Usamos v24.0 por defecto

def send_whatsapp_message(to_number, message_text):
    """Envía la respuesta a Meta y nos dice exactamente qué pasó"""
    url = f"https://graph.facebook.com/{API_VERSION}/{PHONE_NUMBER_ID}/messages"
    headers = {
        "Authorization": f"Bearer {WHATSAPP_TOKEN}",
        "Content-Type": "application/json"
    }
    payload = {
        "messaging_product": "whatsapp",
        "to": to_number,
        "type": "text",
        "text": {"body": message_text}
    }
    
    try:
        response = requests.post(url, json=payload, headers=headers)
        print(f"Respuesta de Meta (Status {response.status_code}): {response.text}")
        return response.json()
    except Exception as e:
        print(f"Error crítico al enviar a Meta: {e}")
        return None

def handler(event, context):
    # 1. Validación del Webhook
    query_params = event.get('queryStringParameters', {})
    if query_params:
        if query_params.get('hub.verify_token') == VERIFY_TOKEN:
            return {'statusCode': 200, 'body': query_params.get('hub.challenge')}
        return {'statusCode': 403, 'body': 'Token inválido'}

    # 2. Procesamiento del Mensaje
    body = json.loads(event.get('body', '{}'))
    
    try:
        # Extraer datos del mensaje
        entry = body['entry'][0]['changes'][0]['value']
        if 'messages' in entry:
            raw_number = entry['messages'][0]['from']
            text = entry['messages'][0]['text']['body']
            
            # LIMPIEZA DE NÚMERO (México): Quitar el '1' si viene como 521...
            # Esto evita errores de envío en la v24.0
            number = raw_number
            if raw_number.startswith("521"):
                number = "52" + raw_number[3:]
            
            print(f"Mensaje de {number}: {text}")

            # 3. Llamada a la IA (Claude 3.5 Sonnet)
            prompt = f"\n\nHuman: Eres un asistente de ventas de lujo. Responde elegante: {text}\n\nAssistant:"
            
            response = bedrock.invoke_model(
                modelId='anthropic.claude-3-5-sonnet-20240620-v1:0',
                body=json.dumps({
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": 500,
                    "messages": [{"role": "user", "content": prompt}]
                })
            )
            
            result = json.loads(response.get('body').read())
            ai_text = result['content'][0]['text']

            # 4. Enviar respuesta final
            send_whatsapp_message(number, ai_text)

    except Exception as e:
        print(f"Error en el proceso: {e}")

    return {'statusCode': 200, 'body': 'OK'}