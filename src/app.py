import os
import json
import boto3
import requests
from botocore.exceptions import ClientError

# 1. Configuración de Clientes
# Usamos 'bedrock-agent-runtime' para interactuar con la Knowledge Base
bedrock_runtime = boto3.client(service_name='bedrock-agent-runtime', region_name='us-east-1')
dynamodb = boto3.resource('dynamodb')

# 2. Variables de Entorno (inyectadas por Terraform)
TABLE_NAME = os.environ.get('TABLE_NAME')
KB_ID = os.environ.get('KNOWLEDGE_BASE_ID')
WHATSAPP_TOKEN = os.environ.get('WHATSAPP_TOKEN')
PHONE_NUMBER_ID = os.environ.get('PHONE_NUMBER_ID')
VERIFY_TOKEN = os.environ.get('VERIFY_TOKEN')

table = dynamodb.Table(TABLE_NAME)

def get_chat_history(session_id):
    """Obtiene los últimos mensajes de DynamoDB"""
    try:
        response = table.get_item(Key={'SessionId': session_id})
        return response.get('Item', {}).get('history', [])
    except ClientError:
        return []

def save_chat_history(session_id, history):
    """Guarda el historial actualizado (limitado a los últimos 10 mensajes)"""
    table.put_item(Item={'SessionId': session_id, 'history': history[-10:]})

def query_knowledge_base(user_input):
    """
    Consulta la Knowledge Base (S3 Vectors). 
    Este método recupera el PDF y genera una respuesta coherente.
    """
    try:
        response = bedrock_runtime.retrieve_and_generate(
            input={'text': user_input},
            retrieveAndGenerateConfiguration={
                'type': 'KNOWLEDGE_BASE',
                'knowledgeBaseConfiguration': {
                    'knowledgeBaseId': KB_ID,
                    'modelArn': 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-sonnet-20240620-v1:0'
                }
            }
        )
        return response['output']['text']
    except Exception as e:
        print(f"Error consultando Bedrock KB: {e}")
        return "Lo siento, tuve un problema al consultar mi base de datos. ¿Puedes repetir la pregunta?"

def send_whatsapp(to, text):
    """Envía el mensaje final al usuario vía Meta API"""
    url = f"https://graph.facebook.com/v18.0/{PHONE_NUMBER_ID}/messages"
    headers = {"Authorization": f"Bearer {WHATSAPP_TOKEN}", "Content-Type": "application/json"}
    payload = {
        "messaging_product": "whatsapp",
        "to": to,
        "type": "text",
        "text": {"body": text}
    }
    return requests.post(url, headers=headers, json=payload)

def lambda_handler(event, context):
    # --- Validar Webhook (GET) ---
    if event.get('requestContext', {}).get('http', {}).get('method') == 'GET':
        params = event.get('queryStringParameters', {})
        if params.get('hub.verify_token') == VERIFY_TOKEN:
            return {'statusCode': 200, 'body': params.get('hub.challenge')}
        return {'statusCode': 403, 'body': 'Token de verificación incorrecto'}

    # --- Procesar Mensaje (POST) ---
    try:
        body = json.loads(event.get('body', '{}'))
        message_data = body['entry'][0]['changes'][0]['value']['messages'][0]
        user_phone = message_data['from']
        user_text = message_data['text']['body']

        # A. Cargar Memoria
        history = get_chat_history(user_phone)
        
        # B. Consultar Conocimiento (RAG)
        # Aquí es donde Bedrock usa los S3 Vectors que configuraste
        ai_response = query_knowledge_base(user_text)

        # C. Guardar Memoria
        history.append({"user": user_text, "bot": ai_response})
        save_chat_history(user_phone, history)

        # D. Responder por WhatsApp
        send_whatsapp(user_phone, ai_response)

    except Exception as e:
        print(f"Error general: {e}")

    return {'statusCode': 200, 'body': 'Procesado'}