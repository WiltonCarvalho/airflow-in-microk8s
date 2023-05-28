FROM apache/airflow:2.3.3-python3.10
ENV TZ=America/Sao_Paulo
RUN set -ex \
    && pip install --no-cache-dir \
        'apache-airflow[crypto,kubernetes,mysql,pandas]==2.3.3' \
        --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-2.3.3/constraints-3.10.txt"
COPY --chown=airflow:root pod_template.yaml /opt/airflow/pod_template.yaml
ARG EXAMPLE_DAGS="/home/airflow/.local/lib/python3.10/site-packages/airflow/example_dags/"
ARG TEST_DAGS="test_dag_*.py"
COPY --chown=airflow:root $TEST_DAGS $EXAMPLE_DAGS