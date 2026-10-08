"""JSON-RPC transport and dispatch; stdin/stdout are reserved for the protocol."""
import json
import os
import sys
from remote_files import FileError, list_directory, read_text

MAX_REQUEST_BYTES = 1024 * 1024
# A 1 MiB text body can grow when JSON escapes its contents.
MAX_RESPONSE_BYTES = 8 * 1024 * 1024


def response(request):
    if not isinstance(request, dict):
        return error(None, -32600, "Invalid Request")
    identifier = request.get("id")
    valid_id = identifier is None or (isinstance(identifier, (str, int, float))
                                      and not isinstance(identifier, bool))
    if (request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str)
            or not valid_id):
        return error(None, -32600, "Invalid Request")
    params = request.get("params", {})
    try:
        method = request["method"]
        if method == "ping":
            if not isinstance(params, (dict, list)) or params:
                raise FileError(-32602, "Invalid params")
            value = {"pid": os.getpid()}
        elif method in ("listDirectory", "readText"):
            if (not isinstance(params, dict) or "root" not in params
                    or set(params) - {"root", "path"}):
                raise FileError(-32602, "Invalid params")
            operation = list_directory if method == "listDirectory" else read_text
            value = operation(params["root"], params.get("path", ""))
        else:
            raise FileError(-32601, "Method not found")
        result = {"jsonrpc": "2.0", "id": identifier, "result": value}
    except FileError as exc:
        result = error(identifier, exc.code, str(exc))
    except OSError as exc:
        result = error(identifier, -32007, "ファイルを取得できません: " + str(exc))
    except UnicodeError:
        result = error(identifier, -32001, "パスを読み込めません。")
    return result if "id" in request else None


def error(identifier, code, message):
    return {"jsonrpc": "2.0", "id": identifier,
            "error": {"code": code, "message": message}}


def reject_constant(value):
    raise ValueError("Invalid JSON constant: " + value)


def encode_response(result):
    encoded = json.dumps(result, separators=(",", ":"), allow_nan=False)
    if len(encoded) + 1 > MAX_RESPONSE_BYTES:
        # ponytail: oversized listings fail explicitly; add paging when needed.
        identifier = result.get("id") if isinstance(result, dict) else None
        encoded = json.dumps(error(identifier, -32008, "取得結果が通信上限を超えています。"),
                             separators=(",", ":"))
    return encoded


def main():
    while True:
        line = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
        if not line:
            return
        if len(line) > MAX_REQUEST_BYTES or not line.endswith(b"\n"):
            print("Invalid or oversized JSON-RPC frame", file=sys.stderr, flush=True)
            return
        try:
            request = json.loads(line, parse_constant=reject_constant)
            if isinstance(request, list) and request:
                result = [response(entry) for entry in request]
                result = [item for item in result if item is not None]
                result = result or None
            else:
                result = response(request)
        except (ValueError, UnicodeError):
            result = error(None, -32700, "Parse error")
        if result is not None:
            print(encode_response(result), flush=True)


if __name__ == "__main__":
    main()
