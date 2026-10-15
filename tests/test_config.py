"""Contract tests for generated configs and untrusted exit bundles."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH_EXE', 'bash')


def shell(code):
    return subprocess.run([BASH, '-c', 'source ./install-vless-chain.sh; ' + code],
                          cwd=ROOT, text=True, capture_output=True)


def output(code):
    result = shell(code)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout


def outbound():
    return json.loads(output("outbound_json 203.0.113.10 24443 "
        "11111111-1111-4111-8111-111111111111 www.cloudflare.com "
        + 'A' * 43 + ' 0123456789abcdef tokyo-exit'))


class ConfigTests(unittest.TestCase):
    def test_host_and_port_injection_is_rejected(self):
        for value in ['x;id', '$(id)', 'a..b', '-bad.com', '999.1.1.1', '1.2.3', 'a/b', 'a\nb']:
            with self.subTest(value=value):
                self.assertNotEqual(shell('valid_host ' + shlex.quote(value)).returncode, 0)
        for value in ['0', '65536', '24443;id', '-1', '01', '1.5']:
            self.assertNotEqual(shell('valid_port ' + shlex.quote(value)).returncode, 0)
        for value in ['203.0.113.10', 'node.example.com', 'www.cloudflare.com']:
            self.assertEqual(shell('valid_host ' + shlex.quote(value)).returncode, 0)

    def test_exit_and_relay_configs_with_real_core(self):
        core = os.environ.get('SING_BOX_BIN')
        self.assertTrue(core, 'Set SING_BOX_BIN to a verified sing-box 1.14.3 executable')
        for role in ['exit', 'relay']:
            out = {'type': 'direct', 'tag': 'direct'} if role == 'exit' else outbound()
            code = ("UUID=11111111-1111-4111-8111-111111111111; PRIVATE_KEY=" + 'A'*43
                    + "; SHORT_ID=0123456789abcdef; SNI=www.cloudflare.com; LISTEN_PORT=24443; render_config "
                    + shlex.quote(json.dumps(out)))
            config = json.loads(output(code))
            self.assertEqual(len(config['inbounds']), 1)
            self.assertEqual(config['inbounds'][0]['type'], 'vless')
            self.assertTrue(config['inbounds'][0]['tls']['reality']['enabled'])
            self.assertEqual(config['inbounds'][0]['users'][0]['flow'], 'xtls-rprx-vision')
            self.assertEqual(config['route']['final'], out['tag'])
            if role == 'relay':
                self.assertEqual([item['type'] for item in config['outbounds']], ['vless'])
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder)/'config.json'
                path.write_text(json.dumps(config), encoding='utf-8')
                result = subprocess.run([core, 'check', '-c', str(path)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_bundle_allowlist_drops_tls_bypass_and_detour(self):
        bundle = {'version': 1, 'outbound': outbound(), 'exit_ip': '203.0.113.10'}
        bundle['outbound']['detour'] = 'direct'
        bundle['outbound']['tls']['insecure'] = True
        bundle['outbound']['tls']['reality']['private_key'] = 'do-not-copy'
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            path = Path(folder)/'bundle.json'
            path.write_text(json.dumps(bundle), encoding='utf-8')
            # Relative fixture paths also work under Git Bash on Windows.
            relative = path.relative_to(ROOT).as_posix()
            result = json.loads(output('validate_bundle ' + shlex.quote(relative)))
            self.assertNotIn('detour', result)
            self.assertNotIn('insecure', result['tls'])
            self.assertNotIn('private_key', result['tls']['reality'])
            self.assertEqual(result['type'], 'vless')
            for bad in ['shadowsocks', 'socks', 'direct']:
                bundle['outbound']['type'] = bad
                path.write_text(json.dumps(bundle), encoding='utf-8')
                self.assertNotEqual(shell('validate_bundle ' + shlex.quote(relative)).returncode, 0)

    def test_rollback_restores_snapshot_and_running_state(self):
        # No root/system paths: sourceable rollback function, fake service commands.
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            base = Path(folder).relative_to(ROOT).as_posix()
            code = f'''
CONF={shlex.quote(base)}/conf; BIN={shlex.quote(base)}/binary; INIT={shlex.quote(base)}/init
mkdir -p "$CONF" {shlex.quote(base)}/old/config
printf 'old-config' > {shlex.quote(base)}/old/config/config.json
printf 'managed' > {shlex.quote(base)}/old/config/managed
printf 'old-binary' > {shlex.quote(base)}/old/binary
printf 'old-service' > {shlex.quote(base)}/old/service
printf '1 1 1 1 1\\n' > {shlex.quote(base)}/old/state
printf 'new-config' > "$CONF/config.json"
printf 'new-binary' > "$BIN"; printf 'new-service' > "$INIT"
rc-service() {{ printf '%s\\n' "$*" >> {shlex.quote(base)}/service-calls; }}
rc-update() {{ :; }}; chown() {{ :; }}
restore_backup {shlex.quote(base)}/old
test "$(cat "$CONF/config.json")" = old-config
test "$(cat "$BIN")" = old-binary
test "$(cat "$INIT")" = old-service
grep -q 'vless-chain start' {shlex.quote(base)}/service-calls
'''
            result = shell(code)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
