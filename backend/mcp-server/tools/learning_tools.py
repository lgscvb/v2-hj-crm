"""
Hour Jungle CRM - AI Learning Tools
AI 學習功能工具：回饋收集、多輪修正、訓練資料匯出

用途：收集操作者對 AI 回覆的回饋，支援多輪修正對話，
      自動偵測知識點並儲存到 Brain RAG 知識庫。
"""

import logging
import os
import json
from datetime import datetime, timedelta
from typing import Dict, Any, Optional, List

import httpx

logger = logging.getLogger(__name__)

# Brain API URL
BRAIN_API_URL = os.getenv("BRAIN_API_URL", "https://brain.yourspce.org")

# PostgREST URL
POSTGREST_URL = os.getenv("POSTGREST_URL", "http://postgrest:3000")

# 改進標籤選項
IMPROVEMENT_TAGS = {
    "tone_too_formal": "語氣太正式",
    "tone_too_casual": "語氣太隨便",
    "too_long": "回覆太長",
    "too_short": "回覆太短",
    "missing_info": "缺少資訊",
    "wrong_info": "資訊錯誤",
    "wrong_tool": "呼叫錯誤工具",
    "slow_response": "回應太慢",
    "not_helpful": "沒有幫助",
    "perfect": "完美",
    "other": "其他"
}

# 操作者意圖分類
OPERATOR_INTENTS = {
    "refinement": "修正指令",
    "decision": "決策確認",
    "emotion": "情緒表達",
    "discussion": "討論對話",
    "question": "提問詢問"
}


# ============================================================================
# 對話記錄
# ============================================================================

async def ai_save_conversation(
    user_message: str,
    assistant_message: str,
    model_used: str,
    session_id: Optional[str] = None,
    operator_name: Optional[str] = None,
    operator_email: Optional[str] = None,
    related_customer_id: Optional[int] = None,
    related_contract_id: Optional[int] = None,
    related_payment_id: Optional[int] = None,
    tool_calls: Optional[List[dict]] = None,
    rag_context: Optional[str] = None,
    input_tokens: int = 0,
    output_tokens: int = 0,
    status: str = "completed"
) -> Dict[str, Any]:
    """
    儲存 AI 對話記錄

    Args:
        user_message: 用戶輸入
        assistant_message: AI 回覆
        model_used: 使用的模型
        session_id: 對話 Session ID（可選）
        operator_name: 操作者姓名（可選）
        operator_email: 操作者 Email（可選）
        related_customer_id: 關聯的客戶 ID（可選）
        related_contract_id: 關聯的合約 ID（可選）
        related_payment_id: 關聯的繳費 ID（可選）
        tool_calls: 執行的工具列表（可選）
        rag_context: RAG 搜尋到的知識（可選）
        input_tokens: 輸入 token 數
        output_tokens: 輸出 token 數
        status: 狀態（completed/error）

    Returns:
        執行結果，包含對話 ID
    """
    payload = {
        "user_message": user_message,
        "assistant_message": assistant_message,
        "model_used": model_used,
        "tool_calls": tool_calls or [],
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "status": status,
        "completed_at": datetime.utcnow().isoformat()
    }

    if session_id:
        payload["session_id"] = session_id
    if operator_name:
        payload["operator_name"] = operator_name
    if operator_email:
        payload["operator_email"] = operator_email
    if related_customer_id:
        payload["related_customer_id"] = related_customer_id
    if related_contract_id:
        payload["related_contract_id"] = related_contract_id
    if related_payment_id:
        payload["related_payment_id"] = related_payment_id
    if rag_context:
        payload["rag_context"] = rag_context

    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{POSTGREST_URL}/ai_conversations",
                json=payload,
                headers={
                    "Content-Type": "application/json",
                    "Prefer": "return=representation"
                },
                timeout=30.0
            )

            if response.status_code in [200, 201]:
                result = response.json()
                # PostgREST 回傳陣列
                conversation = result[0] if isinstance(result, list) else result
                return {
                    "success": True,
                    "conversation_id": conversation.get("id"),
                    "session_id": conversation.get("session_id")
                }
            else:
                logger.error(f"Save conversation failed: {response.status_code} - {response.text}")
                return {
                    "success": False,
                    "message": f"儲存失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_save_conversation error: {e}")
        return {
            "success": False,
            "message": f"儲存失敗: {str(e)}"
        }


async def ai_get_conversation(conversation_id: int) -> Dict[str, Any]:
    """
    取得對話詳情

    Args:
        conversation_id: 對話 ID

    Returns:
        對話詳情
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{POSTGREST_URL}/ai_conversations",
                params={"id": f"eq.{conversation_id}"},
                timeout=30.0
            )

            if response.status_code == 200:
                result = response.json()
                if result:
                    return {
                        "success": True,
                        "conversation": result[0]
                    }
                else:
                    return {
                        "success": False,
                        "message": "對話不存在"
                    }
            else:
                return {
                    "success": False,
                    "message": f"查詢失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_get_conversation error: {e}")
        return {
            "success": False,
            "message": f"查詢失敗: {str(e)}"
        }


# ============================================================================
# 回饋收集
# ============================================================================

async def ai_submit_feedback(
    conversation_id: int,
    is_good: Optional[bool] = None,
    rating: Optional[int] = None,
    feedback_reason: Optional[str] = None,
    improvement_tags: Optional[List[str]] = None,
    submitted_by: Optional[str] = None
) -> Dict[str, Any]:
    """
    提交 AI 回覆回饋

    Args:
        conversation_id: 對話 ID（必填）
        is_good: 快速回饋（True=👍, False=👎）
        rating: 詳細評分（1-5 星）
        feedback_reason: 回饋原因說明
        improvement_tags: 改進標籤列表
            可選值：tone_too_formal, tone_too_casual, too_long, too_short,
                   missing_info, wrong_info, wrong_tool, slow_response,
                   not_helpful, perfect, other
        submitted_by: 提交者名稱

    Returns:
        執行結果
    """
    # 驗證評分範圍
    if rating is not None and (rating < 1 or rating > 5):
        return {
            "success": False,
            "message": "評分必須在 1-5 之間"
        }

    # 驗證標籤
    if improvement_tags:
        invalid_tags = [t for t in improvement_tags if t not in IMPROVEMENT_TAGS]
        if invalid_tags:
            return {
                "success": False,
                "message": f"無效的標籤: {invalid_tags}",
                "valid_tags": list(IMPROVEMENT_TAGS.keys())
            }

    payload = {
        "conversation_id": conversation_id
    }

    if is_good is not None:
        payload["is_good"] = is_good
    if rating is not None:
        payload["rating"] = rating
    if feedback_reason:
        payload["feedback_reason"] = feedback_reason
    if improvement_tags:
        payload["improvement_tags"] = improvement_tags
    if submitted_by:
        payload["submitted_by"] = submitted_by

    try:
        async with httpx.AsyncClient() as client:
            # 先檢查是否已有回饋
            check_response = await client.get(
                f"{POSTGREST_URL}/ai_feedback",
                params={"conversation_id": f"eq.{conversation_id}"},
                timeout=30.0
            )

            if check_response.status_code == 200 and check_response.json():
                # 更新現有回饋
                existing = check_response.json()[0]
                response = await client.patch(
                    f"{POSTGREST_URL}/ai_feedback",
                    params={"id": f"eq.{existing['id']}"},
                    json=payload,
                    headers={
                        "Content-Type": "application/json",
                        "Prefer": "return=representation"
                    },
                    timeout=30.0
                )
            else:
                # 新增回饋
                response = await client.post(
                    f"{POSTGREST_URL}/ai_feedback",
                    json=payload,
                    headers={
                        "Content-Type": "application/json",
                        "Prefer": "return=representation"
                    },
                    timeout=30.0
                )

            if response.status_code in [200, 201]:
                result = response.json()
                feedback = result[0] if isinstance(result, list) else result
                return {
                    "success": True,
                    "message": "回饋已提交",
                    "feedback_id": feedback.get("id")
                }
            else:
                logger.error(f"Submit feedback failed: {response.status_code} - {response.text}")
                return {
                    "success": False,
                    "message": f"提交失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_submit_feedback error: {e}")
        return {
            "success": False,
            "message": f"提交失敗: {str(e)}"
        }


async def ai_get_feedback_stats(days: int = 30) -> Dict[str, Any]:
    """
    取得回饋統計

    Args:
        days: 統計天數（預設 30 天）

    Returns:
        回饋統計資料
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{POSTGREST_URL}/v_ai_feedback_stats",
                params={"limit": days, "order": "date.desc"},
                timeout=30.0
            )

            if response.status_code == 200:
                stats = response.json()
                # 計算總計
                total_feedbacks = sum(s.get("total_feedbacks", 0) for s in stats)
                total_positive = sum(s.get("positive_count", 0) for s in stats)
                total_negative = sum(s.get("negative_count", 0) for s in stats)

                return {
                    "success": True,
                    "summary": {
                        "total_feedbacks": total_feedbacks,
                        "positive_count": total_positive,
                        "negative_count": total_negative,
                        "positive_rate": round(total_positive / total_feedbacks * 100, 1) if total_feedbacks > 0 else 0
                    },
                    "daily_stats": stats
                }
            else:
                return {
                    "success": False,
                    "message": f"查詢失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_get_feedback_stats error: {e}")
        return {
            "success": False,
            "message": f"查詢失敗: {str(e)}"
        }


# ============================================================================
# 多輪修正
# ============================================================================

async def ai_refine_response(
    conversation_id: int,
    instruction: str,
    model: str = "claude-sonnet-4"
) -> Dict[str, Any]:
    """
    提交修正指令，AI 重新生成回覆

    Args:
        conversation_id: 對話 ID（必填）
        instruction: 修正指令（如「語氣更親切」「更簡潔」）
        model: 使用的模型（預設 claude-sonnet-4）

    Returns:
        修正後的內容和知識偵測結果
    """
    # 先取得原始對話
    conv_result = await ai_get_conversation(conversation_id)
    if not conv_result.get("success"):
        return conv_result

    conversation = conv_result["conversation"]
    original_content = conversation.get("assistant_message", "")

    if not original_content:
        return {
            "success": False,
            "message": "原始對話沒有 AI 回覆"
        }

    # 取得目前的修正輪次
    try:
        async with httpx.AsyncClient() as client:
            ref_response = await client.get(
                f"{POSTGREST_URL}/ai_refinements",
                params={
                    "conversation_id": f"eq.{conversation_id}",
                    "order": "round_number.desc",
                    "limit": 1
                },
                timeout=30.0
            )

            if ref_response.status_code == 200 and ref_response.json():
                last_refinement = ref_response.json()[0]
                round_number = last_refinement.get("round_number", 0) + 1
                # 使用上次修正後的內容作為新的原始內容
                original_content = last_refinement.get("refined_content", original_content)
            else:
                round_number = 1

    except Exception as e:
        logger.error(f"Get refinement history error: {e}")
        round_number = 1

    # 組合修正提示詞
    refine_prompt = f"""你是 Hour Jungle 的智能助手，負責根據操作者的指令修正客服回覆。

## 當前回覆內容
{original_content}

## 操作者修正指令
{instruction}

## 任務
1. 根據操作者的指令修正上述回覆
2. 判斷操作者的意圖類型
3. 檢查修正過程中是否有值得儲存的知識點

## 輸出格式（JSON）
{{
    "operator_intent": "refinement/decision/emotion/discussion/question",
    "refined_content": "修正後的回覆內容",
    "modification_types": ["tone", "length", "accuracy"],
    "knowledge_detected": true/false,
    "knowledge_items": [
        {{
            "content": "值得儲存的知識內容",
            "category": "faq/process/service_info/customer_info",
            "reason": "為什麼值得儲存"
        }}
    ]
}}

請確保回覆是有效的 JSON 格式。"""

    # 呼叫 OpenRouter API 進行修正
    try:
        openrouter_key = os.getenv("OPENROUTER_API_KEY", "")
        if not openrouter_key:
            return {
                "success": False,
                "message": "未設定 OPENROUTER_API_KEY"
            }

        # 模型對照
        model_ids = {
            "claude-sonnet-4.5": "anthropic/claude-sonnet-4-20250514",
            "claude-sonnet-4": "anthropic/claude-sonnet-4-20250514",
            "claude-3.5-sonnet": "anthropic/claude-3.5-sonnet",
            "gpt-4o": "openai/gpt-4o",
            "gemini-2.0-flash": "google/gemini-2.0-flash-exp"
        }
        model_id = model_ids.get(model, "anthropic/claude-sonnet-4-20250514")

        async with httpx.AsyncClient() as client:
            ai_response = await client.post(
                "https://openrouter.ai/api/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {openrouter_key}",
                    "Content-Type": "application/json",
                    "HTTP-Referer": "https://hj.yourspce.org",
                    "X-Title": "Hour Jungle CRM"
                },
                json={
                    "model": model_id,
                    "max_tokens": 2500,
                    "messages": [
                        {"role": "user", "content": refine_prompt}
                    ]
                },
                timeout=60.0
            )

            if ai_response.status_code != 200:
                return {
                    "success": False,
                    "message": f"AI API 錯誤: {ai_response.status_code}"
                }

            ai_result = ai_response.json()
            content = ai_result.get("choices", [{}])[0].get("message", {}).get("content", "")

            # 解析 JSON 回覆
            try:
                # 嘗試提取 JSON（可能被包在 ```json``` 中）
                if "```json" in content:
                    content = content.split("```json")[1].split("```")[0]
                elif "```" in content:
                    content = content.split("```")[1].split("```")[0]

                parsed = json.loads(content.strip())
            except json.JSONDecodeError:
                # 如果解析失敗，直接使用原始內容作為修正結果
                parsed = {
                    "operator_intent": "refinement",
                    "refined_content": content,
                    "modification_types": [],
                    "knowledge_detected": False,
                    "knowledge_items": []
                }

            # 儲存修正記錄
            refinement_payload = {
                "conversation_id": conversation_id,
                "round_number": round_number,
                "instruction": instruction,
                "original_content": original_content,
                "refined_content": parsed.get("refined_content", content),
                "operator_intent": parsed.get("operator_intent", "refinement"),
                "modification_types": parsed.get("modification_types", []),
                "knowledge_detected": parsed.get("knowledge_detected", False),
                "knowledge_items": parsed.get("knowledge_items", []),
                "model_used": model,
                "input_tokens": ai_result.get("usage", {}).get("prompt_tokens", 0),
                "output_tokens": ai_result.get("usage", {}).get("completion_tokens", 0)
            }

            save_response = await client.post(
                f"{POSTGREST_URL}/ai_refinements",
                json=refinement_payload,
                headers={
                    "Content-Type": "application/json",
                    "Prefer": "return=representation"
                },
                timeout=30.0
            )

            if save_response.status_code in [200, 201]:
                result = save_response.json()
                refinement = result[0] if isinstance(result, list) else result

                return {
                    "success": True,
                    "refinement_id": refinement.get("id"),
                    "round_number": round_number,
                    "refined_content": parsed.get("refined_content", content),
                    "operator_intent": parsed.get("operator_intent"),
                    "modification_types": parsed.get("modification_types", []),
                    "knowledge_suggestion": {
                        "detected": parsed.get("knowledge_detected", False),
                        "items": parsed.get("knowledge_items", [])
                    }
                }
            else:
                logger.error(f"Save refinement failed: {save_response.status_code}")
                # 即使儲存失敗，仍回傳修正結果
                return {
                    "success": True,
                    "refined_content": parsed.get("refined_content", content),
                    "operator_intent": parsed.get("operator_intent"),
                    "knowledge_suggestion": {
                        "detected": parsed.get("knowledge_detected", False),
                        "items": parsed.get("knowledge_items", [])
                    },
                    "warning": "修正記錄儲存失敗"
                }

    except Exception as e:
        logger.error(f"ai_refine_response error: {e}")
        return {
            "success": False,
            "message": f"修正失敗: {str(e)}"
        }


async def ai_accept_refinement(refinement_id: int) -> Dict[str, Any]:
    """
    標記修正為已接受

    Args:
        refinement_id: 修正記錄 ID

    Returns:
        執行結果
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.patch(
                f"{POSTGREST_URL}/ai_refinements",
                params={"id": f"eq.{refinement_id}"},
                json={"is_accepted": True},
                headers={"Content-Type": "application/json"},
                timeout=30.0
            )

            if response.status_code in [200, 204]:
                return {
                    "success": True,
                    "message": "已標記為接受"
                }
            else:
                return {
                    "success": False,
                    "message": f"更新失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_accept_refinement error: {e}")
        return {
            "success": False,
            "message": f"更新失敗: {str(e)}"
        }


async def ai_reject_refinement(refinement_id: int) -> Dict[str, Any]:
    """
    標記修正為已拒絕

    Args:
        refinement_id: 修正記錄 ID

    Returns:
        執行結果
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.patch(
                f"{POSTGREST_URL}/ai_refinements",
                params={"id": f"eq.{refinement_id}"},
                json={"is_accepted": False},
                headers={"Content-Type": "application/json"},
                timeout=30.0
            )

            if response.status_code in [200, 204]:
                return {
                    "success": True,
                    "message": "已標記為拒絕"
                }
            else:
                return {
                    "success": False,
                    "message": f"更新失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_reject_refinement error: {e}")
        return {
            "success": False,
            "message": f"更新失敗: {str(e)}"
        }


async def ai_get_refinement_history(conversation_id: int) -> Dict[str, Any]:
    """
    取得對話的修正歷史

    Args:
        conversation_id: 對話 ID

    Returns:
        修正歷史列表
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{POSTGREST_URL}/ai_refinements",
                params={
                    "conversation_id": f"eq.{conversation_id}",
                    "order": "round_number.asc"
                },
                timeout=30.0
            )

            if response.status_code == 200:
                return {
                    "success": True,
                    "refinements": response.json()
                }
            else:
                return {
                    "success": False,
                    "message": f"查詢失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_get_refinement_history error: {e}")
        return {
            "success": False,
            "message": f"查詢失敗: {str(e)}"
        }


# ============================================================================
# 訓練資料匯出
# ============================================================================

async def ai_export_training_data(
    export_type: str = "sft",
    min_rating: int = 4,
    include_refinements: bool = True,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None
) -> Dict[str, Any]:
    """
    匯出訓練資料

    Args:
        export_type: 匯出格式（sft/rlhf/dpo）
            - sft: Supervised Fine-Tuning {instruction, input, output}
            - rlhf: Reinforcement Learning {prompt, chosen, rejected}
            - dpo: Direct Preference Optimization {prompt, chosen, rejected, scores}
        min_rating: 最低評分（預設 4）
        include_refinements: 是否包含修正資料（預設 True）
        date_from: 起始日期（格式 YYYY-MM-DD）
        date_to: 結束日期（格式 YYYY-MM-DD）

    Returns:
        匯出的訓練資料
    """
    if export_type not in ["sft", "rlhf", "dpo"]:
        return {
            "success": False,
            "message": f"無效的匯出類型: {export_type}",
            "valid_types": ["sft", "rlhf", "dpo"]
        }

    try:
        async with httpx.AsyncClient() as client:
            # 建構查詢參數
            params = {}

            if date_from:
                params["created_at"] = f"gte.{date_from}"
            if date_to:
                if "created_at" in params:
                    params["and"] = f"(created_at.gte.{date_from},created_at.lte.{date_to})"
                else:
                    params["created_at"] = f"lte.{date_to}"

            # 取得對話資料
            conv_response = await client.get(
                f"{POSTGREST_URL}/ai_conversations",
                params={**params, "status": "eq.completed", "order": "created_at.desc"},
                timeout=60.0
            )

            if conv_response.status_code != 200:
                return {
                    "success": False,
                    "message": f"查詢對話失敗: {conv_response.status_code}"
                }

            conversations = conv_response.json()

            # 取得回饋資料
            fb_response = await client.get(
                f"{POSTGREST_URL}/ai_feedback",
                timeout=60.0
            )
            feedbacks = {f["conversation_id"]: f for f in fb_response.json()} if fb_response.status_code == 200 else {}

            # 取得修正資料
            refinements = {}
            if include_refinements:
                ref_response = await client.get(
                    f"{POSTGREST_URL}/ai_refinements",
                    params={"is_accepted": "eq.true"},
                    timeout=60.0
                )
                if ref_response.status_code == 200:
                    for r in ref_response.json():
                        conv_id = r["conversation_id"]
                        if conv_id not in refinements:
                            refinements[conv_id] = []
                        refinements[conv_id].append(r)

            # 根據匯出類型生成資料
            training_data = []

            if export_type == "sft":
                # SFT 格式：高評分對話
                for conv in conversations:
                    conv_id = conv["id"]
                    feedback = feedbacks.get(conv_id, {})

                    rating = feedback.get("rating", 0)
                    is_good = feedback.get("is_good", False)

                    if rating >= min_rating or is_good:
                        training_data.append({
                            "instruction": "你是 Hour Jungle CRM 的 AI 助手，幫助操作者查詢和管理客戶資料。",
                            "input": conv["user_message"],
                            "output": conv["assistant_message"]
                        })

                    # 加入修正資料
                    if conv_id in refinements:
                        for ref in refinements[conv_id]:
                            training_data.append({
                                "instruction": f"根據以下指令修正回覆：{ref['instruction']}",
                                "input": ref["original_content"],
                                "output": ref["refined_content"]
                            })

            elif export_type == "rlhf":
                # RLHF 格式：被接受 vs 被拒絕的修正
                for conv_id, refs in refinements.items():
                    conv = next((c for c in conversations if c["id"] == conv_id), None)
                    if not conv:
                        continue

                    for ref in refs:
                        if ref.get("is_accepted") is True:
                            training_data.append({
                                "prompt": conv["user_message"],
                                "chosen": ref["refined_content"],
                                "rejected": ref["original_content"]
                            })

            elif export_type == "dpo":
                # DPO 格式：包含評分的偏好對
                for conv in conversations:
                    conv_id = conv["id"]
                    feedback = feedbacks.get(conv_id, {})
                    rating = feedback.get("rating")

                    if rating is not None and conv_id in refinements:
                        for ref in refinements[conv_id]:
                            if ref.get("is_accepted"):
                                training_data.append({
                                    "prompt": conv["user_message"],
                                    "chosen": ref["refined_content"],
                                    "rejected": ref["original_content"],
                                    "chosen_rating": 5,  # 被接受的修正假設為滿分
                                    "rejected_rating": rating
                                })

            # 記錄匯出歷史
            export_record = {
                "export_type": export_type,
                "record_count": len(training_data),
                "filters": {
                    "min_rating": min_rating,
                    "include_refinements": include_refinements,
                    "date_from": date_from,
                    "date_to": date_to
                }
            }

            await client.post(
                f"{POSTGREST_URL}/ai_training_exports",
                json=export_record,
                headers={"Content-Type": "application/json"},
                timeout=30.0
            )

            return {
                "success": True,
                "export_type": export_type,
                "record_count": len(training_data),
                "data": training_data
            }

    except Exception as e:
        logger.error(f"ai_export_training_data error: {e}")
        return {
            "success": False,
            "message": f"匯出失敗: {str(e)}"
        }


async def ai_get_training_stats() -> Dict[str, Any]:
    """
    取得訓練資料統計

    Returns:
        可匯出的訓練資料統計
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{POSTGREST_URL}/v_ai_training_ready",
                timeout=30.0
            )

            if response.status_code == 200:
                stats = response.json()
                return {
                    "success": True,
                    "training_stats": stats
                }
            else:
                return {
                    "success": False,
                    "message": f"查詢失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_get_training_stats error: {e}")
        return {
            "success": False,
            "message": f"查詢失敗: {str(e)}"
        }


# ============================================================================
# 學習模式
# ============================================================================

async def ai_get_learning_patterns(min_count: int = 3) -> Dict[str, Any]:
    """
    取得學習模式

    Args:
        min_count: 最少出現次數（預設 3）

    Returns:
        學習模式列表
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{POSTGREST_URL}/ai_learning_patterns",
                params={
                    "occurrence_count": f"gte.{min_count}",
                    "is_active": "eq.true",
                    "order": "occurrence_count.desc"
                },
                timeout=30.0
            )

            if response.status_code == 200:
                return {
                    "success": True,
                    "patterns": response.json()
                }
            else:
                return {
                    "success": False,
                    "message": f"查詢失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_get_learning_patterns error: {e}")
        return {
            "success": False,
            "message": f"查詢失敗: {str(e)}"
        }


async def ai_list_conversations(
    limit: int = 50,
    offset: int = 0,
    status: Optional[str] = None,
    model: Optional[str] = None
) -> Dict[str, Any]:
    """
    列出對話記錄

    Args:
        limit: 數量限制（預設 50）
        offset: 偏移量（預設 0）
        status: 狀態篩選（可選）
        model: 模型篩選（可選）

    Returns:
        對話列表
    """
    try:
        params = {
            "limit": limit,
            "offset": offset,
            "order": "created_at.desc"
        }

        if status:
            params["status"] = f"eq.{status}"
        if model:
            params["model_used"] = f"eq.{model}"

        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{POSTGREST_URL}/ai_conversations",
                params=params,
                timeout=30.0
            )

            if response.status_code == 200:
                return {
                    "success": True,
                    "conversations": response.json(),
                    "limit": limit,
                    "offset": offset
                }
            else:
                return {
                    "success": False,
                    "message": f"查詢失敗: {response.status_code}"
                }

    except Exception as e:
        logger.error(f"ai_list_conversations error: {e}")
        return {
            "success": False,
            "message": f"查詢失敗: {str(e)}"
        }
