#pulling a docker image with singularity
#apptainer pull carta-backend-1.4.0.sif docker://cartavis/carta-backend:1.4.0
# Pulling Docker image using a Singularity container
apptainer pull carta-backend-1.4.0.sif docker://carta/carta-backend:1.4.0

#Starting carta-backend using Singularity
apptainer exec --cleanenv --bind /data:/data \
  carta-backend-1.4.0.sif \
  /carta-backend/build/carta_backend \
  port=3002 threads=2 omp_threads=4 base=/data

