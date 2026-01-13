FROM public.ecr.aws/lambda/python:3.12

# Copiamos solo el requirements primero para aprovechar el caché de Docker
COPY requirements.txt .

# Instalamos dependencias
RUN pip install --no-cache-dir -r requirements.txt

# Copiamos todo el código de la carpeta backend al contenedor
COPY . ${LAMBDA_TASK_ROOT}/

# Recibimos el nombre del archivo a ejecutar desde Terraform
ARG ENTRY_POINT
CMD [ "${ENTRY_POINT}" ]