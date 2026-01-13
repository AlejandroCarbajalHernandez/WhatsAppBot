#!/bin/bash

# Ruta raíz del proyecto
ROOT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$ROOT_PATH/codigo_filtrado.txt"

# ----------------------------------------------------------------
# CONFIGURACIÓN QUIRÚRGICA (ADAPTADO PARA IA-WHATSAPP-SERVICE)
# ----------------------------------------------------------------

# Carpetas y archivos raíz que queremos inspeccionar
TARGETS=(
    "src"
    "terraform"
    "Dockerfile"
)

# Extensiones válidas a capturar en este stack
EXTENSIONS=(".py" ".txt" ".tf" ".tfvars")

# ----------------------------------------------------------------
# EJECUCIÓN
# ----------------------------------------------------------------

echo -e "\033[0;36mGenerando volcado quirúrgico de IA-WHATSAPP-SERVICE...\033[0m"

# Limpiar o crear el archivo de salida
> "$OUTPUT_FILE"
file_count=0

# Iterar solo sobre los "Targets" definidos
for target in "${TARGETS[@]}"; do
    target_path="$ROOT_PATH/$target"
   
    # Validar si la ruta o archivo realmente existe
    if [ ! -e "$target_path" ]; then
        echo -e "\033[1;31m[Aviso] No se encontró: $target\033[0m"
        continue
    fi

    # Buscar archivos dentro del target (funciona para archivos sueltos o carpetas)
    while IFS= read -r -d '' file; do
        rel_path="${file#$ROOT_PATH/}"

        # 1. Filtro estricto para ignorar archivos y carpetas internas de Terraform/Git
        if [[ "$rel_path" == *".terraform/"* ]] || \
           [[ "$rel_path" == *".git/"* ]] || \
           [[ "$rel_path" == *".tfstate"* ]] || \
           [[ "$rel_path" == *".tfstate.backup"* ]] || \
           [[ "$rel_path" == *".terraform.lock.hcl" ]]; then
            continue
        fi

        # 2. Validar extensión o si es el Dockerfile
        ext_match=0
        if [[ "$(basename "$file")" == "Dockerfile" ]]; then
            ext_match=1
        else
            for ext in "${EXTENSIONS[@]}"; do
                if [[ "$file" == *"$ext" ]]; then
                    ext_match=1
                    break
                fi
            done
        fi
        
        [[ $ext_match -eq 0 ]] && continue

        echo -e "\033[0;32mProcesando: $rel_path\033[0m"

        # Escribir en el archivo
        echo "================================================================================" >> "$OUTPUT_FILE"
        echo "FILE: $rel_path" >> "$OUTPUT_FILE"
        echo "================================================================================" >> "$OUTPUT_FILE"
       
        cat "$file" >> "$OUTPUT_FILE" || echo "[Error reading file]" >> "$OUTPUT_FILE"
       
        echo -e "\n\n" >> "$OUTPUT_FILE"

        ((file_count++))
    done < <(find "$target_path" -type f -print0 2>/dev/null)
done

echo -e "\033[1;33m----------------------------------------------------------------\033[0m"
echo -e "\033[1;33m¡Volcado listo! Guardado en: codigo_filtrado.txt\033[0m"
echo -e "\033[1;33mTotal de archivos procesados: $file_count\033[0m"