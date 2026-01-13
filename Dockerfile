# Forzamos la arquitectura x86_64 que es la estándar de Lambda
FROM --platform=linux/amd64 public.ecr.aws/lambda/python:3.12

# Definimos el argumento de construcción
ARG ENTRY_POINT

# Instalamos dependencias
COPY src/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiamos el código
COPY src/ ${LAMBDA_TASK_ROOT}/

# TRUCO PRO: Sobrescribimos el CMD directamente con el valor del argumento
# Esto evita que Lambda intente buscar una variable de entorno en tiempo de ejecución
ENV LAMBDA_HANDLER_VALUE=${ENTRY_POINT}
CMD [ "app.lambda_handler" ]