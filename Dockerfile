# Forzamos la arquitectura x86_64 que es la estándar de Lambda
FROM --platform=linux/amd64 public.ecr.aws/lambda/python:3.12

# ... (el resto del archivo se queda igual)
COPY src/requirements.txt .
RUN pip install -r requirements.txt
COPY src/app.py ${LAMBDA_TASK_ROOT}
CMD [ "app.lambda_handler" ]