"""Copy AWSCURRENT secret values from this account to a destination account.

Creates the destination secret when it does not exist; otherwise updates the value.
Deletes (and restores) destination secrets to match source DeleteSecret / RestoreSecret.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SECRET_PREFIX = os.environ.get("SECRET_PREFIX", "prefix/")
DEST_ROLE_ARN = os.environ.get("DEST_ROLE_ARN", "")
EXTERNAL_ID = os.environ.get("EXTERNAL_ID", "")
DEST_REGION = os.environ.get("DEST_REGION") or os.environ.get("AWS_REGION")


def _secret_id_from_event(event: dict[str, Any]) -> str | None:
    detail = event.get("detail") or {}
    params = detail.get("requestParameters") or {}
    resp = detail.get("responseElements") or {}
    return (
        params.get("secretId")
        or params.get("name")
        or resp.get("arn")
        or resp.get("name")
    )


def secret_name_from_id(secret_id: str) -> str:
    """Turn a Secrets Manager name or ARN into the secret name."""
    if ":secret:" not in secret_id:
        return secret_id
    after = secret_id.split(":secret:", 1)[1]
    if "-" in after:
        return after.rsplit("-", 1)[0]
    return after


def _is_failed_api_call(event: dict[str, Any]) -> bool:
    detail = event.get("detail") or {}
    return bool(detail.get("errorCode") or detail.get("errorMessage"))


def _is_replica_event(event: dict[str, Any]) -> bool:
    extra = (event.get("detail") or {}).get("additionalEventData") or {}
    if not isinstance(extra, dict):
        return False
    if extra.get("isReplica") is True:
        return True
    if extra.get("replicationStatus"):
        return True
    invoked = str(extra.get("invokedFrom") or "").lower()
    return "replica" in invoked


def _values_equal(source: dict[str, Any], dest: dict[str, Any]) -> bool:
    if "SecretString" in source or "SecretString" in dest:
        return source.get("SecretString") == dest.get("SecretString")
    return source.get("SecretBinary") == dest.get("SecretBinary")


def _source_payload(source_value: dict[str, Any]) -> dict[str, Any]:
    if "SecretString" in source_value and source_value["SecretString"] is not None:
        return {"SecretString": source_value["SecretString"]}
    return {"SecretBinary": source_value["SecretBinary"]}


def _dest_client():
    sts = boto3.client("sts")
    creds = sts.assume_role(
        RoleArn=DEST_ROLE_ARN,
        RoleSessionName="secret-sync",
        ExternalId=EXTERNAL_ID,
    )["Credentials"]
    return boto3.client(
        "secretsmanager",
        region_name=DEST_REGION,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def _truthy(value: Any) -> bool:
    return value in (True, "true", "True")


def _sync_delete(dest_sm: Any, name: str, event: dict[str, Any]) -> dict[str, Any]:
    params = (event.get("detail") or {}).get("requestParameters") or {}
    kwargs: dict[str, Any] = {"SecretId": name}
    if _truthy(params.get("forceDeleteWithoutRecovery")):
        kwargs["ForceDeleteWithoutRecovery"] = True
    elif params.get("recoveryWindowInDays") is not None:
        kwargs["RecoveryWindowInDays"] = int(params["recoveryWindowInDays"])

    try:
        dest_sm.delete_secret(**kwargs)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code == "ResourceNotFoundException":
            logger.info("Destination secret %s already absent; delete is a no-op", name)
            return {"status": "skipped", "reason": "dest_missing", "name": name}
        if code == "InvalidRequestException":
            logger.info(
                "Destination secret %s could not be deleted (already scheduled or invalid): %s",
                name,
                exc.response.get("Error", {}).get("Message"),
            )
            return {"status": "skipped", "reason": "invalid_delete", "name": name}
        raise
    logger.info("Deleted destination secret %s", name)
    return {"status": "deleted", "name": name}


def _restore_dest_if_needed(dest_sm: Any, name: str) -> None:
    try:
        dest_sm.restore_secret(SecretId=name)
        logger.info("Restored destination secret %s", name)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code in ("ResourceNotFoundException", "InvalidRequestException"):
            return
        raise


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    event_name = (event.get("detail") or {}).get("eventName")
    if _is_failed_api_call(event):
        logger.info("Skipping failed Secrets Manager API call eventName=%s", event_name)
        return {"status": "skipped", "reason": "failed_api_call"}

    if _is_replica_event(event):
        logger.info("Skipping replica event eventName=%s", event_name)
        return {"status": "skipped", "reason": "replica"}

    secret_id = _secret_id_from_event(event)
    if not secret_id:
        logger.info("No secret id in event eventName=%s; skipping", event_name)
        return {"status": "skipped", "reason": "no_secret_id"}

    name = secret_name_from_id(secret_id)
    if not name.startswith(SECRET_PREFIX):
        logger.info("Secret %s does not match prefix %s; skipping", name, SECRET_PREFIX)
        return {"status": "skipped", "reason": "prefix", "name": name}

    logger.info("Syncing secret %s from eventName=%s", name, event_name)

    dest_sm = _dest_client()
    if event_name == "DeleteSecret":
        return _sync_delete(dest_sm, name, event)

    if event_name == "RestoreSecret":
        _restore_dest_if_needed(dest_sm, name)

    source_sm = boto3.client("secretsmanager")
    source_meta = source_sm.describe_secret(SecretId=name)
    source_value = source_sm.get_secret_value(SecretId=name, VersionStage="AWSCURRENT")
    payload = _source_payload(source_value)

    try:
        dest_meta = dest_sm.describe_secret(SecretId=name)
        if dest_meta.get("DeletedDate"):
            _restore_dest_if_needed(dest_sm, name)
        dest_value = dest_sm.get_secret_value(SecretId=name, VersionStage="AWSCURRENT")
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code == "ResourceNotFoundException":
            return _create_dest_secret(dest_sm, name, payload, source_meta)
        raise

    if _values_equal(source_value, dest_value):
        logger.info("Secret %s already in sync", name)
        return {"status": "unchanged", "name": name}

    dest_sm.put_secret_value(SecretId=name, **payload)
    logger.info("Updated destination secret %s", name)
    return {"status": "updated", "name": name}


def _create_dest_secret(
    dest_sm: Any,
    name: str,
    payload: dict[str, Any],
    source_meta: dict[str, Any],
) -> dict[str, Any]:
    create_args: dict[str, Any] = {"Name": name, **payload}
    description = source_meta.get("Description")
    if description:
        create_args["Description"] = description
    try:
        dest_sm.create_secret(**create_args)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code == "ResourceExistsException":
            dest_sm.put_secret_value(SecretId=name, **payload)
            logger.info("Destination secret %s appeared concurrently; updated value", name)
            return {"status": "updated", "name": name}
        raise
    logger.info("Created destination secret %s", name)
    return {"status": "created", "name": name}
