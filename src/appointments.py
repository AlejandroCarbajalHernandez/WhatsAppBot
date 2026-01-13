# FORZANDO DEPLOY: VERSION 2.0
import os
import json
import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

# Inicialización de recursos
dynamodb = boto3.resource('dynamodb')
# Asegúrate de que esta variable de entorno esté en tu main.tf
table = dynamodb.Table(os.environ['APPOINTMENTS_TABLE'])

def lambda_handler(event, context):
    print(f"Evento recibido de Bedrock: {json.dumps(event)}")
    
    # 1. Extraer datos del NUEVO formato (Function Schema)
    action_group = event.get('actionGroup', 'CitasMedicas')
    funcion = event.get('function', '')
    
    # Extraer parámetros y convertirlos a un diccionario limpio
    parametros_crudos = event.get('parameters', [])
    params = {p['name']: p['value'] for p in parametros_crudos}
    
    date = params.get('date')
    
    # Atributos de sesión para identificar al usuario
    session_attrs = event.get('sessionAttributes', {})
    user_phone = session_attrs.get('user_phone', 'Desconocido')

    # Usaremos una variable de texto para la respuesta que leerá Nova Lite
    resultado_texto = ""

    try:
        # --- CASO 1: CONSULTAR DISPONIBILIDAD (getAvailability) ---
        if funcion == 'getAvailability':
            # Buscamos en el GSI 'DateIndex' todos los horarios para esa fecha
            response = table.query(
                IndexName='DateIndex',
                KeyConditionExpression=Key('appointment_date').eq(date)
            )
            
            # Filtramos solo los que están marcados como 'disponible'
            items = response.get('Items', [])
            available_slots = [
                item['appointment_id'].split('#')[1] 
                for item in items 
                if item.get('availability_status') == 'disponible'
            ]
            
            if available_slots:
                # Le pasamos a Bedrock un string claro con las horas
                resultado_texto = f"Horarios disponibles para el {date}: {', '.join(available_slots)}"
            else:
                resultado_texto = f"No hay horarios disponibles para el día {date}."

        # --- CASO 2: AGENDAR CITA (bookAppointment) ---
        elif funcion == 'bookAppointment':
            time = params.get('time')
            # 1. Capturamos el nombre completo que nos mandará Bedrock
            patient_name = params.get('name', 'Desconocido') 
            appointment_id = f"{date}#{time}"
            
            try:
                # Intentamos actualizar solo si el estado actual es 'disponible'
                table.update_item(
                    Key={'doctor_id': 'DOC-001', 'appointment_id': appointment_id},
                    # 2. Agregamos patient_name a la expresión de actualización
                    UpdateExpression="SET availability_status = :r, patient_phone = :p, patient_name = :n",
                    ConditionExpression="availability_status = :d",
                    ExpressionAttributeValues={
                        ':r': 'reservado',
                        ':p': user_phone,
                        ':n': patient_name, # 3. Mapeamos la variable aquí
                        ':d': 'disponible'
                    }
                )
                resultado_texto = f"¡Cita confirmada! Te esperamos el {date} a las {time}."
            except ClientError as e:
                if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                    resultado_texto = "Lo siento, ese horario ya no está disponible."
                else:
                    raise e
                    
        else:
            resultado_texto = f"Error: La función '{funcion}' no fue reconocida."

    except Exception as e:
        print(f"Error interno en base de datos: {str(e)}")
        resultado_texto = f"Error interno al procesar la solicitud en la base de datos."

    # --- FORMATO DE RESPUESTA FINAL OBLIGATORIO PARA BEDROCK NATIVO ---
    # Esto es lo que previene el Error 409 (DependencyFailedException)
    api_response = {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": action_group,
            "function": funcion,
            "functionResponse": {
                "responseBody": {
                    "TEXT": {
                        "body": resultado_texto
                    }
                }
            }
        }
    }

    return api_response