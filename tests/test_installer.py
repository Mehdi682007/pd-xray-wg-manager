"""No root, network access, or system changes required."""
import ast
import datetime
import decimal
import os
from pathlib import Path
import re
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'pd-xray-wg-manager.sh'
SOURCE = SCRIPT.read_text(encoding='utf-8')


class InstallerTests(unittest.TestCase):
    def test_python_syntax(self):
        for body in re.findall(r"<<'PY'\n(.*?)\nPY", SOURCE, re.S):
            ast.parse(body)
        ast.parse(SOURCE.split("<<'LIMITS_PY'\n", 1)[1].split('\nLIMITS_PY', 1)[0])

    def test_expiry_and_volume(self):
        engine = SOURCE.split("<<'LIMITS_PY'\n", 1)[1].split('\nLIMITS_PY', 1)[0]
        fn = next(n for n in ast.parse(engine).body if isinstance(n, ast.FunctionDef) and n.name == 'parse_limit')
        scope = {'decimal': decimal, 'dt': datetime, 're': re}
        exec(compile(ast.Module(body=[fn], type_ignores=[]), 'embedded-parser', 'exec'), scope)
        parse = scope['parse_limit']
        for days in ('30', '+30'):
            self.assertEqual(parse('25', days, 1000), (25_000_000_000, 2_593_000))
        self.assertEqual(parse('0', '0', 1000), (0, 0))
        for value in ('NaN', 'Infinity', '-1'):
            with self.assertRaises(ValueError):
                parse(value, '30', 1000)
        with self.assertRaises(ValueError):
            parse('25', 'not-a-date', 1000)

    def test_quick_does_not_create_client(self):
        code = '''source "$1"
requirements() { :; }
configure_proxy() { :; }
configure_wg() { :; }
configure_routing() { :; }
health() { :; }
e2e() { :; }
client_create() { echo UNEXPECTED; return 99; }
quick
'''
        result = subprocess.run([os.environ.get('BASH_BIN', 'bash'), '-c', code, 'test', SCRIPT.as_posix()], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNEXPECTED', result.stdout)

    def test_e2e_avoids_fixed_test_network(self):
        self.assertNotIn("ns=xgw-e2e", SOURCE)
        self.assertNotIn('192.0.2.1/30', SOURCE)
        self.assertIn("route','show','table','all", SOURCE)
        self.assertIn('No unused RFC 5737 /30', SOURCE)
        self.assertIn('trap - ERR', SOURCE)
        self.assertIn("x!='10.66.66.1/24'", SOURCE)
        self.assertIn('IFS=$\' \\t\' read -r net_pair host_addr client_addr', SOURCE)


if __name__ == '__main__':
    unittest.main()
