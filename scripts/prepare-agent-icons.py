#!/usr/bin/env python3
"""Rasterize the checked-in brand SVGs with Apple's renderer, without dependencies.

CoreSVG misreads compact arc flags such as '0 013.046'. Expand separators
without changing any path values. Run on macOS after updating the source SVGs.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
NUMBER = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?')
ARITY = dict(M=2, L=2, H=1, V=1, C=6, S=4, Q=4, T=2, A=7)


def separated_path(path):
    parts, index, command = [], 0, None
    while index < len(path):
        while index < len(path) and path[index] in ' ,\t\r\n':
            index += 1
        if index == len(path):
            break
        if path[index].isalpha():
            command = path[index]
            parts.append(command)
            index += 1
            if command.upper() == 'Z':
                command = None
                continue
        if command is None or command.upper() not in ARITY:
            raise ValueError('Unsupported SVG path command')
        for argument in range(ARITY[command.upper()]):
            while index < len(path) and path[index] in ' ,\t\r\n':
                index += 1
            if command.upper() == 'A' and argument in (3, 4):
                if index >= len(path) or path[index] not in '01':
                    raise ValueError('Invalid SVG arc flag')
                parts.append(path[index])
                index += 1
            else:
                match = NUMBER.match(path, index)
                if match is None:
                    raise ValueError('Incomplete SVG path')
                parts.append(match.group())
                index = match.end()
    return ' '.join(parts)


def main():
    ET.register_namespace('', 'http://www.w3.org/2000/svg')
    directory = ROOT / 'App/Resources/AgentIcons'
    with tempfile.TemporaryDirectory(prefix='notchx-brand-') as temporary:
        for name in ['codex', 'claude']:
            tree = ET.parse(directory / (name + '.svg'))
            tree.getroot().set('width', '96')
            tree.getroot().set('height', '96')
            for element in tree.iter():
                if 'd' in element.attrib:
                    element.set('d', separated_path(element.attrib['d']))
            svg = Path(temporary) / (name + '.svg')
            tree.write(svg, encoding='unicode')
            result = subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(svg), '--out', str(directory / (name + '.png'))], capture_output=True, text=True, check=True)
            if 'CoreSVG' in result.stderr or 'CoreSVG' in result.stdout:
                raise RuntimeError('Brand rendering failed: ' + result.stderr + result.stdout)
            print('Prepared ' + name + '.png')


if __name__ == '__main__':
    main()
