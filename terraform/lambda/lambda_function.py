import os
import json
import uuid
from datetime import datetime

import boto3
import pg8000


secrets_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")


def get_db_creds(secret_arn):
    resp = secrets_client.get_secret_value(SecretId=secret_arn)
    secret_string = resp.get("SecretString")
    return json.loads(secret_string)


def write_to_s3(bucket, payload):
    key = f"events/{datetime.utcnow().strftime('%Y/%m/%d')}/{uuid.uuid4().hex}.json"
    s3_client.put_object(Bucket=bucket, Key=key, Body=json.dumps(payload).encode("utf-8"))
    return key


def insert_into_postgres(conn, payload):
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO audit.events (source, event_type, payload) VALUES (%s, %s, %s)",
        ("github-actions", payload.get("event"), json.dumps(payload)),
    )
    conn.commit()
    cur.close()


def lambda_handler(event, context):
    secret_arn = os.environ["SECRET_ARN"]
    db_host = os.environ["DB_HOST"]
    db_port = int(os.environ.get("DB_PORT", "5432"))
    db_name = os.environ["DB_NAME"]
    s3_bucket = os.environ["S3_BUCKET"]

    creds = get_db_creds(secret_arn)
    db_user = creds["username"]
    db_pass = creds["password"]

    conn = pg8000.connect(
        host=db_host,
        port=db_port,
        user=db_user,
        password=db_pass,
        database=db_name,
        timeout=30
    )

    records = event.get("Records", [])
    for rec in records:
        body = rec.get("body")
        try:
            payload = json.loads(body)
        except Exception:
            payload = {"raw": body}

        insert_into_postgres(conn, payload)

        write_to_s3(s3_bucket, payload)

    conn.close()
    return {"status": "ok", "processed": len(records)}
