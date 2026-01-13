import boto3
from datetime import datetime, timedelta

# Configuración
REGION = "us-east-1"
TABLE_NAME = "agencia-lujo-medical-appointments" 

dynamodb = boto3.resource('dynamodb', region_name=REGION)
table = dynamodb.Table(TABLE_NAME)

def populate():
    doctor_id = "DOC-001"
    
    # Obtenemos la fecha exacta del sistema al momento de ejecutar
    start_date = datetime.now() 
    
    print(f"Iniciando inyección de base de datos a partir del {start_date.strftime('%Y-%m-%d')}...")
    
    # Generamos espacios para hoy y los próximos 4 días
    for i in range(5):
        current_date = (start_date + timedelta(days=i)).strftime("%Y-%m-%d")
        
        # Horarios de oficina ampliados
        slots = ["09:00", "10:00", "11:00", "12:00", "13:00", "14:00"]
        
        for slot in slots:
            appointment_id = f"{current_date}#{slot}"
            
            print(f"Insertando hueco: {appointment_id}...")
            
            table.put_item(
                Item={
                    'doctor_id': doctor_id,
                    'appointment_id': appointment_id,
                    'appointment_date': current_date,
                    'availability_status': 'disponible',
                    'patient_phone': 'ninguno',
                    'patient_name': 'ninguno'
                }
            )

if __name__ == "__main__":
    try:
        populate()
        print("\n✅ ¡Éxito! El inventario de citas para esta semana ha sido inyectado en DynamoDB.")
    except Exception as e:
        print(f"\n❌ Error: {str(e)}")