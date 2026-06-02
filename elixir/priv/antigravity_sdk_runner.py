#!/usr/bin/env python3
"""JSONL bridge between Symphony and Google Antigravity SDK."""

from __future__ import annotations

import asyncio
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn


@dataclass(frozen=True)
class StartRequest:
    cwd: Path
    model: str | None
    api_key: str | None
    app_data_dir: Path | None
    save_dir: Path | None
    approval_policy: str


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def fail(message: str, *, detail: str | None = None) -> NoReturn:
    payload: dict[str, Any] = {"event": "turn_failed", "error": {"message": message}}
    if detail:
        payload["error"]["detail"] = detail
    emit(payload)
    raise SystemExit(1)


def optional_path(value: str | None) -> Path | None:
    if value is None or value == "":
        return None
    return Path(value)


def parse_start(payload: dict[str, Any]) -> StartRequest:
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        fail("start request requires a non-empty cwd")

    approval_policy = payload.get("approval_policy") or "never"
    if approval_policy not in {"never", "on-request"}:
        fail(f"unsupported approval policy: {approval_policy}")

    return StartRequest(
        cwd=Path(cwd),
        model=payload.get("model"),
        api_key=payload.get("api_key"),
        app_data_dir=optional_path(payload.get("app_data_dir")),
        save_dir=optional_path(payload.get("save_dir")),
        approval_policy=approval_policy,
    )


async def run() -> None:
    try:
        from google.antigravity import Agent, CapabilitiesConfig, LocalAgentConfig
        from google.antigravity.hooks import hooks, policy
        from google.antigravity import types
    except ImportError as err:
        fail(
            "google-antigravity is not installed; install it with `pip install google-antigravity`",
            detail=str(err),
        )

    start_line = sys.stdin.readline()
    if start_line == "":
        fail("missing start request")

    start_payload = json.loads(start_line)
    if start_payload.get("op") != "start":
        fail("first request must be op=start")

    request = parse_start(start_payload)
    os.chdir(request.cwd)

    @hooks.on_interaction
    async def non_interactive_question(
        data: types.AskQuestionInteractionSpec,
    ) -> types.QuestionHookResult:
        responses = [
            types.QuestionResponse(freeform_response="This is a non-interactive Symphony session. Operator input is unavailable.")
            for _question in data.questions
        ]
        emit({"event": "turn_input_required", "questions": [str(question) for question in data.questions]})
        return types.QuestionHookResult(responses=responses)

    def non_interactive_approval(tool_call: types.ToolCall) -> bool:
        emit(
            {
                "event": "approval_required",
                "tool": tool_call.name,
                "arguments": str(tool_call.args),
            }
        )
        return False

    if request.approval_policy == "never":
        sdk_policies = [policy.allow_all()]
    else:
        sdk_policies = [policy.allow_all(), policy.ask_user("*", handler=non_interactive_approval)]

    sdk_hooks = [non_interactive_question]

    kwargs: dict[str, Any] = {
        "capabilities": CapabilitiesConfig(),
        "policies": sdk_policies,
        "hooks": sdk_hooks,
    }

    if request.model:
        kwargs["model"] = request.model
    if request.api_key:
        kwargs["api_key"] = request.api_key
    if request.app_data_dir:
        kwargs["app_data_dir"] = str(request.app_data_dir)
    if request.save_dir:
        kwargs["save_dir"] = str(request.save_dir)

    config = LocalAgentConfig(**kwargs)

    async with Agent(config) as agent:
        conversation_id = str(agent.conversation_id or "antigravity-session")
        emit(
            {
                "event": "session_started",
                "session_id": conversation_id,
                "thread_id": conversation_id,
                "metadata": {"provider": "antigravity_sdk"},
            }
        )

        for line in sys.stdin:
            payload = json.loads(line)
            op = payload.get("op")

            if op == "stop":
                return

            if op != "turn":
                emit({"event": "notification", "method": "antigravity/event/ignored", "params": {"op": op}})
                continue

            prompt = payload.get("prompt")
            if not isinstance(prompt, str) or not prompt:
                emit({"event": "turn_failed", "error": {"message": "turn request requires a non-empty prompt"}})
                continue

            try:
                response = await agent.chat(prompt)
                async for token in response:
                    emit(
                        {
                            "event": "notification",
                            "method": "antigravity/event/agent_message_delta",
                            "params": {"delta": token},
                        }
                    )

                usage = agent.conversation.total_usage
                emit(
                    {
                        "event": "token_count",
                        "input_tokens": usage.prompt_token_count,
                        "output_tokens": usage.candidates_token_count,
                        "total_tokens": usage.total_token_count,
                    }
                )
                emit({"event": "turn_completed", "turn_id": f"turn-{agent.conversation.turn_count}", "result": "turn_completed"})
            except Exception as err:  # pylint: disable=broad-except
                emit({"event": "turn_failed", "error": {"message": str(err), "type": type(err).__name__}})


def main() -> None:
    try:
        asyncio.run(run())
    except json.JSONDecodeError as err:
        fail("invalid JSON request", detail=str(err))


if __name__ == "__main__":
    main()
