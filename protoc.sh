#!/usr/bin/env bash
# protoc.sh — raw-protoc fallback for react-native-sinch-push codegen.
#
# The preferred path is `npm run proto:gen`, which delegates to `buf generate`
# using buf.gen.yaml at the repo root. This script exists as a thin wrapper
# around raw `protoc` for environments without `buf`, and to expose a
# `--target` flag so a single subtree (push | chat | app) can be regenerated
# on its own.
#
# The only plugin used is `@bufbuild/protoc-gen-es` (Protobuf-ES v2 line).
# The legacy `protoc-gen-connect-es` plugin was removed in Connect-ES v2 and
# must NOT be added back — see research/connect-rn-toolchain.md §1.
#
# Usage:
#   sh ./protoc.sh                     # generate --target=all (default)
#   sh ./protoc.sh --target=push       # generate only the push subtree
#   sh ./protoc.sh --target=chat       # generate only the chat subtree
#   sh ./protoc.sh --target=app        # generate only the in-app-message cut
#   sh ./protoc.sh --clean             # wipe src/generated/ and exit
#   sh ./protoc.sh --help              # show this help text and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROTO_DIR="proto"
OUT_DIR="src/generated"

usage() {
  cat <<EOF
protoc.sh — raw-protoc fallback for react-native-sinch-push codegen

USAGE
  sh ./protoc.sh [--target=push|chat|app|all] [--clean] [--help]

FLAGS
  --target=<name>   Subtree to build. One of: push | chat | app | all.
                    Default: all (uses 'find proto -name *.proto').
  --clean           Remove everything under src/generated/ and exit.
  --help, -h        Show this help text and exit.

OUTPUT
  TypeScript files are written to src/generated/. Each .proto produces a
  matching *_pb.ts containing both message *Schema descriptors and the
  GenService constant for every service declared in the proto (Protobuf-ES
  v2 pattern; no separate *_connect.ts files).

PLUGIN
  Resolved at node_modules/.bin/protoc-gen-es via \$PATH. Install with:
    npm install --save-dev @bufbuild/protoc-gen-es

DEPENDENCIES
  - protoc on \$PATH (e.g. Homebrew: brew install protobuf)
  - @bufbuild/protoc-gen-es (npm devDep)

FILE LISTS PER TARGET
  See research/sinch-proto-contracts.md §3 for the rationale behind each cut.
EOF
}

TARGET="all"
CLEAN=0

for arg in "$@"; do
  case "$arg" in
    --target=*)
      TARGET="${arg#--target=}"
      ;;
    --clean)
      CLEAN=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown flag '$arg'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$TARGET" in
  push|chat|app|all) ;;
  *)
    echo "error: invalid --target '$TARGET'. Use one of: push | chat | app | all." >&2
    exit 1
    ;;
esac

if [ "$CLEAN" = "1" ]; then
  if [ -d "$OUT_DIR" ]; then
    rm -rf "$OUT_DIR"
    echo "removed $OUT_DIR/"
  else
    echo "$OUT_DIR/ does not exist; nothing to remove"
  fi
  exit 0
fi

if ! command -v protoc >/dev/null 2>&1; then
  echo "error: 'protoc' not on PATH." >&2
  echo "  install via Homebrew with: brew install protobuf" >&2
  exit 1
fi

PLUGIN_BIN="node_modules/.bin/protoc-gen-es"
if [ ! -x "$PLUGIN_BIN" ]; then
  echo "error: $PLUGIN_BIN not found or not executable." >&2
  echo "  install with: npm install --save-dev @bufbuild/protoc-gen-es" >&2
  exit 1
fi

push_protos() {
  cat <<'EOF'
proto/sinch/push/sdk/v1beta1/sdk.proto
EOF
}

chat_protos() {
  cat <<'EOF'
proto/sinch/chat/sdk/v1alpha2/sdk.proto
proto/sinch/chat/sdk/v1alpha2/resources.proto
proto/sinch/conversationapi/type/conversation_message.proto
proto/sinch/conversationapi/type/conversation_event.proto
proto/sinch/conversationapi/type/contact.proto
proto/sinch/conversationapi/type/conversation_channel.proto
proto/sinch/conversationapi/type/coordinates.proto
proto/sinch/conversationapi/type/reason.proto
proto/sinch/conversationapi/type/agent.proto
proto/sinch/conversationapi/type/processing_mode.proto
proto/sinch/conversationapi/type/message_status.proto
proto/sinch/conversationapi/type/status.proto
EOF
}

app_protos() {
  cat <<'EOF'
proto/sinch/conversationapi/type/conversation_message.proto
proto/sinch/conversationapi/type/contact.proto
proto/sinch/conversationapi/type/conversation_channel.proto
proto/sinch/conversationapi/type/coordinates.proto
proto/sinch/conversationapi/type/reason.proto
proto/sinch/conversationapi/type/agent.proto
proto/sinch/conversationapi/type/processing_mode.proto
proto/sinch/conversationapi/type/message_status.proto
proto/sinch/conversationapi/type/status.proto
EOF
}

case "$TARGET" in
  push)
    PROTOS=$(push_protos)
    ;;
  chat)
    PROTOS=$(chat_protos)
    ;;
  app)
    PROTOS=$(app_protos)
    ;;
  all)
    PROTOS=$(find proto -name '*.proto' | LC_ALL=C sort)
    ;;
esac

if [ -z "$PROTOS" ]; then
  echo "error: --target=$TARGET resolved to an empty proto file list." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

export PATH="$PATH:$(pwd)/node_modules/.bin"

# shellcheck disable=SC2086 # $PROTOS is intentionally word-split into positional args
protoc \
  --proto_path="$PROTO_DIR" \
  --es_out="$OUT_DIR" \
  --es_opt=target=ts \
  $PROTOS

echo "generated TypeScript to $OUT_DIR/ (target=$TARGET)"