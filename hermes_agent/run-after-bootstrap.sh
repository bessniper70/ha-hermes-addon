#!/bin/bash
set -euo pipefail

OPTIONS_FILE="/data/options.json"
HERMES_DATA_DIR="/data"
WORKSPACE_DIR="${HERMES_DATA_DIR}/workspace"
INTERNAL_API_KEY_FILE="${HERMES_DATA_DIR}/.ha_api_server_key"
HERMES_PYTHON="/opt/hermes/.venv/bin/python"

if [ ! -f "${OPTIONS_FILE}" ]; then
  echo "Missing ${OPTIONS_FILE}"
  exit 1
fi

mkdir -p "${WORKSPACE_DIR}"
mkdir -p "${HERMES_DATA_DIR}/nginx/body" "${HERMES_DATA_DIR}/nginx/proxy" "${HERMES_DATA_DIR}/nginx/fastcgi" "${HERMES_DATA_DIR}/nginx/uwsgi" "${HERMES_DATA_DIR}/nginx/scgi"

if [ ! -f "${INTERNAL_API_KEY_FILE}" ]; then
  "${HERMES_PYTHON}" - <<'PY'
from pathlib import Path
import secrets

path = Path('/data/.ha_api_server_key')
path.write_text(secrets.token_hex(32) + '\n', encoding='utf-8')
path.chmod(0o600)
PY
fi

"${HERMES_PYTHON}" - <<'PY'
from pathlib import Path
import json
import re

import yaml

home = Path('/data')
options = json.loads((home / 'options.json').read_text(encoding='utf-8'))
config_path = home / 'config.yaml'
env_path = home / '.env'

config = {}
if config_path.exists():
    loaded = yaml.safe_load(config_path.read_text(encoding='utf-8'))
    if isinstance(loaded, dict):
        config = loaded

timezone = str(options.get('timezone') or 'UTC').strip() or 'UTC'
model_provider = str(options.get('model_provider') or 'auto').strip() or 'auto'
model_name = str(options.get('model_name') or 'google/gemini-2.5-flash').strip() or 'google/gemini-2.5-flash'
model_base_url = str(options.get('model_base_url') or '').strip()
hass_token = str(options.get('hass_token') or '').strip()
hass_url = str(options.get('hass_url') or '').strip()
hass_entity_allowlist = str(options.get('hass_entity_allowlist') or '').strip()
gateway_timeout_raw = options.get('gateway_timeout')
gateway_timeout = 1800 if gateway_timeout_raw in (None, '') else int(gateway_timeout_raw)

model = config.setdefault('model', {})
model['provider'] = model_provider
model['default'] = model_name
if model_base_url:
    model['base_url'] = model_base_url
else:
    model.pop('base_url', None)

# Enable the official Home Assistant plugin platform only when a token is configured.
# Preserve any user-defined event filters already present in config.yaml.
if hass_token:
    platforms = config.setdefault('platforms', {})
    homeassistant = platforms.setdefault('homeassistant', {})
    homeassistant['enabled'] = True
    if hass_url:
        extra = homeassistant.setdefault('extra', {})
        extra['url'] = hass_url

terminal = config.setdefault('terminal', {})
terminal['backend'] = 'local'
terminal['cwd'] = '/data/workspace'
terminal['timeout'] = 180
terminal['lifetime_seconds'] = 300

agent = config.setdefault('agent', {})
agent['gateway_timeout'] = gateway_timeout

display = config.setdefault('display', {})
display['compact'] = True

config_text = yaml.safe_dump(config, sort_keys=False, allow_unicode=False)
config_path.write_text(config_text, encoding='utf-8')

managed = {
    'TZ': timezone,
    'OPENROUTER_API_KEY': str(options.get('openrouter_api_key') or '').strip(),
    'GOOGLE_API_KEY': str(options.get('google_api_key') or '').strip(),
    'GEMINI_API_KEY': str(options.get('google_api_key') or '').strip(),
    'ANTHROPIC_API_KEY': str(options.get('anthropic_api_key') or '').strip(),
    'OPENAI_API_KEY': str(options.get('openai_api_key') or '').strip(),
    'HASS_TOKEN': hass_token,
    'HASS_URL': hass_url,
    'HASS_ENTITY_ALLOWLIST': hass_entity_allowlist,
}

begin = '# BEGIN HA-HERMES-ADDON'
end = '# END HA-HERMES-ADDON'
existing = ''
if env_path.exists():
    existing = env_path.read_text(encoding='utf-8')

pattern = re.compile(r'\n?# BEGIN HA-HERMES-ADDON\n.*?# END HA-HERMES-ADDON\n?', re.S)
existing = re.sub(pattern, '\n', existing).rstrip()

managed_lines = [begin]
for key, value in managed.items():
    if value:
        escaped = value.replace('\\', '\\\\').replace('"', '\\"')
        managed_lines.append(f'{key}="{escaped}"')
managed_lines.append(end)

parts = []
if existing:
    parts.append(existing)
parts.append('\n'.join(managed_lines))
env_path.write_text('\n\n'.join(parts).rstrip() + '\n', encoding='utf-8')
PY

# Export add-on settings into s6-overlay's persistent container environment.
# The upstream image owns PID 1 and starts its services through s6; a legacy
# custom ENTRYPOINT would bypass supervision and break the dashboard/gateway.
S6_ENV_DIR="/run/s6/container_environment"
mkdir -p "${S6_ENV_DIR}"
write_s6_env() {
  printf '%s' "$2" > "${S6_ENV_DIR}/$1"
  chmod 0644 "${S6_ENV_DIR}/$1"
}

TZ_VALUE="$("${HERMES_PYTHON}" - <<'PY'
import json
from pathlib import Path
options = json.loads(Path('/data/options.json').read_text(encoding='utf-8'))
print(options.get('timezone') or 'UTC')
PY
)"
write_s6_env TZ "${TZ_VALUE}"
write_s6_env HERMES_DASHBOARD 1
write_s6_env HERMES_DASHBOARD_HOST 127.0.0.1
write_s6_env HERMES_DASHBOARD_PORT 9120
ENABLE_DASHBOARD_TUI="$("${HERMES_PYTHON}" - <<'PY'
import json
from pathlib import Path
options = json.loads(Path('/data/options.json').read_text(encoding='utf-8'))
print('true' if options.get('enable_dashboard_tui') else 'false')
PY
)"
if [ "${ENABLE_DASHBOARD_TUI}" = "true" ]; then
  write_s6_env HERMES_DASHBOARD_TUI 1
fi
write_s6_env API_SERVER_ENABLED true
write_s6_env API_SERVER_HOST 127.0.0.1
write_s6_env API_SERVER_KEY "$(tr -d '\r\n' < "${INTERNAL_API_KEY_FILE}")"
chmod 0600 "${S6_ENV_DIR}/API_SERVER_KEY"

ENABLE_TERMINAL="$("${HERMES_PYTHON}" - <<'PY'
import json
from pathlib import Path
options = json.loads(Path('/data/options.json').read_text(encoding='utf-8'))
print('true' if options.get('enable_terminal', True) else 'false')
PY
)"
write_s6_env ENABLE_TERMINAL "${ENABLE_TERMINAL}"

# Install the official HA plugin into the default profile when a token is configured.
# Installation failures are non-fatal so Telegram/Gemini and the gateway can still start.
if [ -n "${hass_token}" ]; then
  if ! s6-setuidgid hermes env HOME=/data HERMES_HOME=/data /opt/hermes/.venv/bin/hermes plugins install homeassistant; then
    echo "[addon] WARNING: Home Assistant plugin installation failed; check network and retry from the terminal."
  fi
fi


