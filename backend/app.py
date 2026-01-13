from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import boto3
import os
import awsgi
from io import BytesIO
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib import colors

app = Flask(__name__)
CORS(app)

# DynamoDB instance initialization
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')

# Se enlaza a la variable inyectada por Terraform en tu main.tf
table_name = os.environ.get('APPOINTMENTS_TABLE', 'agencia-lujo-medical-appointments')
appointments_table = dynamodb.Table(table_name)

@app.route('/api/doctor/<doctor_id>', methods=['GET', 'POST'])
def handle_doctor(doctor_id):
    if request.method == 'GET':
        response = appointments_table.get_item(Key={'doctor_id': doctor_id, 'appointment_id': 'metadata_profile'})
        return jsonify(response.get('Item', {}))
    
    elif request.method == 'POST':
        data = request.json
        appointments_table.put_item(Item={
            'doctor_id': doctor_id,
            'appointment_id': 'metadata_profile',
            'fullName': data.get('fullName'),
            'professionalId': data.get('professionalId'),
            'education': data.get('education'),
            'degree': data.get('degree'),
            'schedule': data.get('schedule')
        })
        return jsonify({"message": "Profile updated successfully"}), 200

@app.route('/api/patients/<doctor_id>', methods=['GET'])
def get_patients(doctor_id):
    try:
        response = appointments_table.query(
            KeyConditionExpression=boto3.dynamodb.conditions.Key('doctor_id').eq(doctor_id)
        )
        items = response.get('Items', [])
        
        patients = []
        for item in items:
            # Skip the metadata row
            if item.get('appointment_id') == 'metadata_profile':
                continue
            
            # Parse the composite sort key (e.g., "2026-01-28#11:00") into clean strings
            sort_key = item.get('appointment_id', '')
            date_part = item.get('appointment_date', '')
            time_part = 'N/A'
            
            if '#' in sort_key:
                parts = sort_key.split('#')
                date_part = parts[0]
                time_part = parts[1]

            patients.append({
                'appointment_id': sort_key,
                'doctor_id': item.get('doctor_id'),
                'date': date_part,
                'time': time_part,
                'status': item.get('availability_status', 'disponible'),
                'cellphone': item.get('patient_phone', 'ninguno'),
                'fullName': item.get('patient_name', 'Registered Patient') # Use saved name or fallback
            })
            
        return jsonify(patients)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/appointments/<doctor_id>/<path:appointment_id>/confirm', methods=['POST'])
def confirm_appointment(doctor_id, appointment_id):
    # Overwrite availability_status string keyword to flag confirmations
    appointments_table.update_item(
        Key={'doctor_id': doctor_id, 'appointment_id': appointment_id},
        UpdateExpression="set availability_status = :s",
        ExpressionAttributeValues={':s': 'confirmado'}
    )
    return jsonify({"message": "Appointment confirmed successfully"}), 200

@app.route('/api/appointments/<doctor_id>/<path:appointment_id>/notes', methods=['POST'])
def save_notes(doctor_id, appointment_id):
    data = request.json
    appointments_table.update_item(
        Key={'doctor_id': doctor_id, 'appointment_id': appointment_id},
        UpdateExpression="set notes = :n, prescription_data = :p",
        ExpressionAttributeValues={
            ':n': data.get('notes'),
            ':p': data.get('prescription')
        }
    )
    return jsonify({"message": "Notes synchronized"}), 200

@app.route('/api/generate-pdf', methods=['POST'])
def generate_pdf():
    data = request.json
    doctor = data.get('doctor', {})
    patient = data.get('patient', {})
    prescription_text = data.get('prescriptionText', '')

    buffer = BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=letter, rightMargin=40, leftMargin=40, topMargin=40, bottomMargin=40)
    story = []
    
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle('DocTitle', parent=styles['Heading1'], fontSize=22, textColor=colors.HexColor("#1e3a8a"))
    sub_style = ParagraphStyle('DocSub', parent=styles['Normal'], fontSize=10, textColor=colors.gray)
    body_style = ParagraphStyle('DocBody', parent=styles['Normal'], fontSize=12, spaceBefore=15, leading=16)

    story.append(Paragraph(f"Dr. {doctor.get('fullName', 'Medical Specialist')}", title_style))
    story.append(Paragraph(f"Degree: {doctor.get('degree', 'N/A')} | Professional ID: {doctor.get('professionalId', 'N/A')}", sub_style))
    story.append(Paragraph(f"Education: {doctor.get('education', 'N/A')}", sub_style))
    story.append(Spacer(1, 20))
    
    story.append(Paragraph("<hr color='#1e3a8a' width='100%'/>", styles['Normal']))
    story.append(Spacer(1, 15))

    story.append(Paragraph(f"<b>Patient:</b> {patient.get('fullName')} &nbsp;&nbsp;&nbsp;&nbsp; <b>Contact Phone:</b> {patient.get('cellphone')}", styles['Normal']))
    story.append(Paragraph(f"<b>Appointment Date:</b> {patient.get('date')} &nbsp;&nbsp;&nbsp;&nbsp; <b>Time:</b> {patient.get('time')}", styles['Normal']))
    story.append(Spacer(1, 20))

    story.append(Paragraph("<b>Rx / Treatment Indications:</b>", styles['Heading2']))
    story.append(Paragraph(prescription_text.replace('\n', '<br/>'), body_style))
    
    doc.build(story)
    buffer.seek(0)
    
    return send_file(buffer, as_attachment=True, download_name=f"Prescription_{patient.get('fullName')}.pdf", mimetype='application/pdf')

# --- CÓDIGO PARA AWS LAMBDA ---
# Traduce la solicitud HTTP de AWS a un formato que Flask entiende
# --- CÓDIGO PARA AWS LAMBDA ---
# Traduce la solicitud HTTP de AWS a un formato que Flask y awsgi entienden
# --- CÓDIGO PARA AWS LAMBDA ---
# Traduce la solicitud HTTP de AWS a un formato que Flask entiende
def lambda_handler(event, context):
    # Parche de compatibilidad: Traducir Function URL (Payload v2) a API Gateway (Payload v1)
    if 'httpMethod' not in event:
        event['httpMethod'] = event.get('requestContext', {}).get('http', {}).get('method', 'GET')
    
    if 'path' not in event:
        event['path'] = event.get('rawPath', '/')
        
    # NUEVO PARCHE: awsgi explota si no encuentra estas llaves, así que las inyectamos vacías
    if 'queryStringParameters' not in event or event['queryStringParameters'] is None:
        event['queryStringParameters'] = {}
        
    if 'multiValueQueryStringParameters' not in event or event['multiValueQueryStringParameters'] is None:
        event['multiValueQueryStringParameters'] = {}
        
    return awsgi.response(app, event, context, base64_content_types={"application/pdf"})