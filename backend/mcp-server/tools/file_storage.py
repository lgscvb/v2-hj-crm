"""
Hour Jungle CRM - File Storage Tools
文件存儲工具（Cloudflare R2）

支援功能：
- file_upload: 上傳文件到 R2
- file_get_signed_url: 產生簽名下載 URL
- file_log_access: 記錄存取日誌
- file_list: 列出實體相關文件
- file_delete: 軟刪除文件
"""

import logging
import os
from datetime import datetime
from typing import Dict, Any, Optional
import base64

import httpx

logger = logging.getLogger(__name__)

# PostgREST URL
POSTGREST_URL = os.getenv("POSTGREST_URL", "http://postgrest:3000")

# Cloudflare R2 配置（S3-compatible）
R2_ACCOUNT_ID = os.getenv("R2_ACCOUNT_ID", "")
R2_ACCESS_KEY_ID = os.getenv("R2_ACCESS_KEY_ID", "")
R2_SECRET_ACCESS_KEY = os.getenv("R2_SECRET_ACCESS_KEY", "")
R2_BUCKET_NAME = os.getenv("R2_BUCKET_NAME", "hourjungle-files")

# R2 Endpoint
R2_ENDPOINT = f"https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com" if R2_ACCOUNT_ID else ""

# 簽名 URL 預設過期時間（秒）
DEFAULT_URL_EXPIRY = 1209600  # 2 週（14 天）


def get_r2_client():
    """取得 R2 客戶端（boto3 S3 client）"""
    if not R2_ACCOUNT_ID or not R2_ACCESS_KEY_ID or not R2_SECRET_ACCESS_KEY:
        logger.warning("R2 credentials not configured")
        return None

    try:
        import boto3
        from botocore.config import Config

        client = boto3.client(
            's3',
            endpoint_url=R2_ENDPOINT,
            aws_access_key_id=R2_ACCESS_KEY_ID,
            aws_secret_access_key=R2_SECRET_ACCESS_KEY,
            config=Config(signature_version='s3v4'),
            region_name='auto'  # R2 使用 'auto'
        )
        return client
    except Exception as e:
        logger.error(f"Failed to create R2 client: {e}")
        return None


async def postgrest_get(endpoint: str, params: dict = None) -> Any:
    """PostgREST GET 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    async with httpx.AsyncClient() as client:
        response = await client.get(url, params=params, timeout=30.0)
        response.raise_for_status()
        return response.json()


async def postgrest_post(endpoint: str, data: dict) -> Any:
    """PostgREST POST 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    headers = {
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }
    async with httpx.AsyncClient() as client:
        response = await client.post(url, json=data, headers=headers, timeout=30.0)
        response.raise_for_status()
        return response.json()


async def postgrest_patch(endpoint: str, params: dict, data: dict) -> Any:
    """PostgREST PATCH 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    headers = {
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }
    async with httpx.AsyncClient() as client:
        response = await client.patch(url, params=params, json=data, headers=headers, timeout=30.0)
        response.raise_for_status()
        return response.json()


# ============================================================================
# File Storage Tools
# ============================================================================

async def file_upload(
    file_content: str,
    file_name: str,
    file_type: str,
    entity_type: str,
    entity_id: int,
    content_type: str = "application/pdf",
    uploaded_by_id: int = None,
    uploaded_by_name: str = None
) -> Dict[str, Any]:
    """
    上傳文件到 R2

    Args:
        file_content: Base64 編碼的文件內容
        file_name: 原始文件名
        file_type: 文件類型 (contract_pdf, quote, invoice, attachment)
        entity_type: 關聯類型 (contract, quote, customer)
        entity_id: 關聯 ID
        content_type: MIME 類型
        uploaded_by_id: 上傳者 ID
        uploaded_by_name: 上傳者名稱

    Returns:
        上傳結果，包含 file_path
    """
    # 驗證參數
    valid_file_types = ["contract_pdf", "quote", "invoice", "attachment", "other"]
    if file_type not in valid_file_types:
        return {
            "success": False,
            "error": f"無效的文件類型，允許: {', '.join(valid_file_types)}",
            "code": "INVALID_FILE_TYPE"
        }

    valid_entity_types = ["contract", "quote", "customer", "payment"]
    if entity_type not in valid_entity_types:
        return {
            "success": False,
            "error": f"無效的實體類型，允許: {', '.join(valid_entity_types)}",
            "code": "INVALID_ENTITY_TYPE"
        }

    # 解碼 Base64 內容
    try:
        file_bytes = base64.b64decode(file_content)
        file_size = len(file_bytes)
    except Exception as e:
        return {
            "success": False,
            "error": f"Base64 解碼失敗: {e}",
            "code": "DECODE_ERROR"
        }

    # 生成 R2 路徑
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    file_path = f"{entity_type}s/{entity_id}/{file_type}_{timestamp}_{file_name}"

    # 上傳到 R2
    r2_client = get_r2_client()
    if not r2_client:
        return {
            "success": False,
            "error": "R2 存儲未配置或無法連接",
            "code": "STORAGE_NOT_CONFIGURED"
        }

    try:
        r2_client.put_object(
            Bucket=R2_BUCKET_NAME,
            Key=file_path,
            Body=file_bytes,
            ContentType=content_type
        )
    except Exception as e:
        logger.error(f"R2 upload failed: {e}")
        return {
            "success": False,
            "error": f"上傳失敗: {e}",
            "code": "UPLOAD_FAILED"
        }

    # 寫入 files 索引表
    try:
        file_record = await postgrest_post("files", {
            "file_path": file_path,
            "file_name": file_name,
            "file_type": file_type,
            "file_size": file_size,
            "content_type": content_type,
            "entity_type": entity_type,
            "entity_id": entity_id,
            "storage_provider": "r2",
            "status": "active",
            "uploaded_by_id": uploaded_by_id,
            "uploaded_by_name": uploaded_by_name
        })

        file_id = file_record[0]["id"] if isinstance(file_record, list) else file_record["id"]
    except Exception as e:
        logger.error(f"Failed to create file record: {e}")
        file_id = None

    # 記錄存取日誌
    try:
        await postgrest_post("file_access_logs", {
            "file_path": file_path,
            "file_name": file_name,
            "file_type": file_type,
            "file_size": file_size,
            "content_type": content_type,
            "entity_type": entity_type,
            "entity_id": entity_id,
            "action": "upload",
            "user_id": uploaded_by_id,
            "user_name": uploaded_by_name,
            "user_type": "staff"
        })
    except Exception as e:
        logger.warning(f"Failed to log file access: {e}")

    return {
        "success": True,
        "message": f"文件上傳成功: {file_name}",
        "file_id": file_id,
        "file_path": file_path,
        "file_name": file_name,
        "file_size": file_size,
        "entity_type": entity_type,
        "entity_id": entity_id
    }


async def file_get_signed_url(
    file_path: str,
    expiry_seconds: int = DEFAULT_URL_EXPIRY,
    user_id: int = None,
    user_name: str = None,
    ip_address: str = None
) -> Dict[str, Any]:
    """
    產生文件的簽名下載 URL

    Args:
        file_path: R2 文件路徑
        expiry_seconds: URL 過期時間（秒），預設 1 小時
        user_id: 存取者 ID（用於日誌）
        user_name: 存取者名稱
        ip_address: 存取者 IP

    Returns:
        包含簽名 URL 的結果
    """
    r2_client = get_r2_client()
    if not r2_client:
        return {
            "success": False,
            "error": "R2 存儲未配置",
            "code": "STORAGE_NOT_CONFIGURED"
        }

    # 檢查文件是否存在於索引
    try:
        files = await postgrest_get("files", {
            "file_path": f"eq.{file_path}",
            "status": "eq.active"
        })
        if not files:
            return {
                "success": False,
                "error": "找不到文件或已刪除",
                "code": "NOT_FOUND"
            }
        file_record = files[0]
    except Exception as e:
        logger.warning(f"File record lookup failed: {e}")
        file_record = None

    # 產生簽名 URL
    try:
        signed_url = r2_client.generate_presigned_url(
            'get_object',
            Params={
                'Bucket': R2_BUCKET_NAME,
                'Key': file_path
            },
            ExpiresIn=expiry_seconds
        )
    except Exception as e:
        logger.error(f"Failed to generate signed URL: {e}")
        return {
            "success": False,
            "error": f"產生簽名 URL 失敗: {e}",
            "code": "URL_GENERATION_FAILED"
        }

    # 記錄存取日誌
    try:
        await postgrest_post("file_access_logs", {
            "file_path": file_path,
            "file_name": file_record.get("file_name") if file_record else None,
            "file_type": file_record.get("file_type") if file_record else None,
            "entity_type": file_record.get("entity_type") if file_record else None,
            "entity_id": file_record.get("entity_id") if file_record else None,
            "action": "download",
            "user_id": user_id,
            "user_name": user_name,
            "user_type": "staff",
            "ip_address": ip_address,
            "metadata": {
                "expiry_seconds": expiry_seconds,
                "expires_at": (datetime.now().timestamp() + expiry_seconds)
            }
        })
    except Exception as e:
        logger.warning(f"Failed to log file access: {e}")

    expires_at = datetime.now().timestamp() + expiry_seconds

    return {
        "success": True,
        "signed_url": signed_url,
        "file_path": file_path,
        "file_name": file_record.get("file_name") if file_record else None,
        "expires_at": datetime.fromtimestamp(expires_at).isoformat(),
        "expiry_seconds": expiry_seconds
    }


async def file_list(
    entity_type: str,
    entity_id: int,
    file_type: str = None,
    include_deleted: bool = False
) -> Dict[str, Any]:
    """
    列出實體相關的所有文件

    Args:
        entity_type: 實體類型 (contract, quote, customer)
        entity_id: 實體 ID
        file_type: 文件類型篩選（可選）
        include_deleted: 是否包含已刪除文件

    Returns:
        文件列表
    """
    try:
        params = {
            "entity_type": f"eq.{entity_type}",
            "entity_id": f"eq.{entity_id}",
            "order": "created_at.desc"
        }

        if not include_deleted:
            params["status"] = "eq.active"

        if file_type:
            params["file_type"] = f"eq.{file_type}"

        files = await postgrest_get("files", params)

        return {
            "success": True,
            "entity_type": entity_type,
            "entity_id": entity_id,
            "file_count": len(files),
            "files": files
        }

    except Exception as e:
        logger.error(f"file_list failed: {e}")
        return {
            "success": False,
            "error": f"查詢失敗: {e}",
            "code": "QUERY_FAILED"
        }


async def file_delete(
    file_path: str,
    reason: str = None,
    deleted_by_id: int = None,
    deleted_by_name: str = None,
    hard_delete: bool = False
) -> Dict[str, Any]:
    """
    刪除文件（預設軟刪除）

    Args:
        file_path: R2 文件路徑
        reason: 刪除原因
        deleted_by_id: 刪除者 ID
        deleted_by_name: 刪除者名稱
        hard_delete: 是否真的從 R2 刪除（預設 False = 軟刪除）

    Returns:
        刪除結果
    """
    # 查詢文件記錄
    try:
        files = await postgrest_get("files", {"file_path": f"eq.{file_path}"})
        if not files:
            return {
                "success": False,
                "error": "找不到文件記錄",
                "code": "NOT_FOUND"
            }
        file_record = files[0]
    except Exception as e:
        logger.error(f"file_delete lookup failed: {e}")
        return {"success": False, "error": f"查詢失敗: {e}"}

    if file_record.get("status") == "deleted":
        return {
            "success": False,
            "error": "文件已刪除",
            "code": "ALREADY_DELETED"
        }

    # 軟刪除：更新狀態
    try:
        await postgrest_patch(
            "files",
            {"file_path": f"eq.{file_path}"},
            {
                "status": "deleted",
                "deleted_at": datetime.now().isoformat()
            }
        )
    except Exception as e:
        logger.error(f"file_delete update failed: {e}")
        return {"success": False, "error": f"更新失敗: {e}"}

    # 如果是硬刪除，從 R2 真的刪除
    if hard_delete:
        r2_client = get_r2_client()
        if r2_client:
            try:
                r2_client.delete_object(Bucket=R2_BUCKET_NAME, Key=file_path)
            except Exception as e:
                logger.warning(f"R2 hard delete failed: {e}")

    # 記錄存取日誌
    try:
        await postgrest_post("file_access_logs", {
            "file_path": file_path,
            "file_name": file_record.get("file_name"),
            "file_type": file_record.get("file_type"),
            "entity_type": file_record.get("entity_type"),
            "entity_id": file_record.get("entity_id"),
            "action": "delete",
            "user_id": deleted_by_id,
            "user_name": deleted_by_name,
            "user_type": "staff",
            "metadata": {
                "reason": reason,
                "hard_delete": hard_delete
            }
        })
    except Exception as e:
        logger.warning(f"Failed to log file delete: {e}")

    return {
        "success": True,
        "message": f"文件已{'永久' if hard_delete else ''}刪除",
        "file_path": file_path,
        "file_name": file_record.get("file_name"),
        "hard_delete": hard_delete
    }


async def file_log_access(
    file_path: str,
    action: str,
    user_id: int = None,
    user_name: str = None,
    user_type: str = "staff",
    ip_address: str = None,
    user_agent: str = None,
    metadata: dict = None
) -> Dict[str, Any]:
    """
    記錄文件存取日誌（用於審計追蹤）

    Args:
        file_path: 文件路徑
        action: 操作類型 (view, download, upload, delete)
        user_id: 使用者 ID
        user_name: 使用者名稱
        user_type: 使用者類型 (staff, customer, system)
        ip_address: IP 位址
        user_agent: 瀏覽器資訊
        metadata: 額外資訊

    Returns:
        日誌 ID
    """
    valid_actions = ["view", "download", "upload", "delete", "share"]
    if action not in valid_actions:
        return {
            "success": False,
            "error": f"無效的操作類型，允許: {', '.join(valid_actions)}",
            "code": "INVALID_ACTION"
        }

    # 查詢文件資訊
    try:
        files = await postgrest_get("files", {"file_path": f"eq.{file_path}"})
        file_record = files[0] if files else None
    except:
        file_record = None

    try:
        log_data = {
            "file_path": file_path,
            "file_name": file_record.get("file_name") if file_record else None,
            "file_type": file_record.get("file_type") if file_record else None,
            "entity_type": file_record.get("entity_type") if file_record else None,
            "entity_id": file_record.get("entity_id") if file_record else None,
            "action": action,
            "user_id": user_id,
            "user_name": user_name,
            "user_type": user_type,
            "ip_address": ip_address,
            "user_agent": user_agent,
            "metadata": metadata or {}
        }

        result = await postgrest_post("file_access_logs", log_data)
        log_id = result[0]["id"] if isinstance(result, list) else result["id"]

        return {
            "success": True,
            "log_id": log_id,
            "action": action,
            "file_path": file_path
        }

    except Exception as e:
        logger.error(f"file_log_access failed: {e}")
        return {
            "success": False,
            "error": f"記錄失敗: {e}",
            "code": "LOG_FAILED"
        }
