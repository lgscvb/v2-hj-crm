"""
postgrest_client.py - PostgREST 客戶端

提供統一的 PostgREST API 介面
支援 dependency injection 模式，可在 main.py 注入共用的請求函數

Date: 2025-12-31
"""

import os
from typing import Any, Optional

import httpx

POSTGREST_URL = os.getenv("POSTGREST_URL", "http://postgrest:3000")


# Dependency injection pattern
_injected_request = None


def set_postgrest_request(func):
    """
    注入 postgrest_request 函數
    允許從 main.py 注入共用的請求處理函數
    """
    global _injected_request
    _injected_request = func


async def postgrest_request(
    method: str,
    endpoint: str,
    params: Optional[dict] = None,
    data: Optional[dict] = None,
    headers: Optional[dict] = None
) -> Any:
    """
    發送 PostgREST 請求

    Args:
        method: HTTP 方法 (GET, POST, PATCH, DELETE)
        endpoint: API 端點（不含 base URL）
        params: Query 參數
        data: Request body（用於 POST/PATCH）
        headers: 額外的 headers

    Returns:
        API 回應（JSON 解析後）
    """
    # 如果有注入的函數，使用它
    if _injected_request:
        return await _injected_request(method, endpoint, params=params, data=data, headers=headers)

    # 否則使用內建的 httpx 請求
    url = f"{POSTGREST_URL}/{endpoint}"

    default_headers = {
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    if headers:
        default_headers.update(headers)

    async with httpx.AsyncClient() as client:
        if method.upper() == "GET":
            response = await client.get(url, params=params, headers=default_headers)
        elif method.upper() == "POST":
            response = await client.post(url, json=data, params=params, headers=default_headers)
        elif method.upper() == "PATCH":
            response = await client.patch(url, json=data, params=params, headers=default_headers)
        elif method.upper() == "DELETE":
            response = await client.delete(url, params=params, headers=default_headers)
        else:
            raise ValueError(f"不支援的 HTTP 方法: {method}")

        response.raise_for_status()

        # 處理空回應
        if response.status_code == 204 or not response.content:
            return []

        return response.json()
