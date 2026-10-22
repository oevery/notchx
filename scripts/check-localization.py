#!/usr/bin/env python3
"""Portable source/resource checks. These do not validate macOS runtime rendering.

Parses .strings as key/value pairs, rejects duplicates and malformed residue,
compares actual catalog keys against non-interpolated SwiftUI/L10n call sites,
and verifies each translation preserves printf argument types. Dynamic data and
SwiftUI interpolation need separate runtime checks on macOS.
"""
import collections
import json
import plistlib
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1] / "App"
QUOTED = r'"(?:[^"\\]|\\.)*"'
PAIR = re.compile(r'(' + QUOTED + r')\s*=\s*(' + QUOTED + r')\s*;')
CALL = re.compile(r'(?:\b(?:Text|Button|Label|Toggle|Picker|Section|GroupBox|SettingNote|SettingSupportingText)|L10n\.(?:text|format)|\.(?:help|alert|accessibilityLabel|navigationTitle))\s*\(\s*(' + QUOTED + r')')
ARG = re.compile(r'\b(?:title|description|subtitle|messageText|informativeText|grantedTitle|unit)\s*:\s*(' + QUOTED + r')')
JOB_NAME = re.compile(r'\bregister\s*\(\s*id\s*:\s*' + QUOTED + r'\s*,\s*name\s*:\s*(' + QUOTED + r')')
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.\d+)?(ll|l|h|z|t|j)?([@diuoxXfFeEgGcs])')

def decode(value):
    return json.loads(value)

def parse_catalog(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    values = {}
    offset = 0
    for match in PAIR.finditer(text):
        if text[offset:match.start()].strip():
            raise ValueError('Malformed .strings content before ' + match.group(1))
        key, value = map(decode, match.groups())
        if key in values:
            raise ValueError('Duplicate localization key: ' + key)
        values[key] = value
        offset = match.end()
    if text[offset:].strip():
        raise ValueError('Malformed trailing .strings content')
    return values

def placeholders(text):
    # Ignore literal percent escapes, preserving integer-width distinctions.
    return collections.Counter((length or '') + kind for _, length, kind in FORMAT.findall(text.replace('%%', '')))

def literal_keys(source):
    source = re.sub(r'^\s*//.*$', '', source, flags=re.M)
    result = set()
    for pattern in (CALL, ARG, JOB_NAME):
        for match in pattern.finditer(source):
            raw = match.group(1)
            if r'\(' in raw:
                continue
            try:
                key = decode(raw)
            except ValueError:
                continue
            if key and not key.isspace():
                result.add(key)
    return result

def validate(root=ROOT):
    en = parse_catalog((root / 'Resources/en.lproj/Localizable.strings').read_text())
    zh = parse_catalog((root / 'Resources/zh-Hans.lproj/Localizable.strings').read_text())
    errors = []
    if set(en) != set(zh):
        errors.append('English/Chinese key sets differ: ' + repr(sorted(set(en) ^ set(zh))))
    for key in sorted(set(en) & set(zh)):
        if not en[key].strip() or not zh[key].strip():
            errors.append('Empty translation: ' + key)
        if placeholders(en[key]) != placeholders(zh[key]):
            errors.append('Format argument mismatch: ' + key)
    info = plistlib.loads((root / 'Info.plist').read_bytes())
    usage_keys = {key for key in info if key.endswith('UsageDescription')}
    for locale in ('en', 'zh-Hans'):
        privacy = parse_catalog((root / f'Resources/{locale}.lproj/InfoPlist.strings').read_text())
        for key in usage_keys:
            if not privacy.get(key, '').strip():
                errors.append(f'{locale}: missing privacy usage translation {key}')
    for path in sorted(root.rglob('*.swift')):
        for key in sorted(literal_keys(path.read_text()) - set(en)):
            errors.append(str(path.relative_to(root)) + ': missing key ' + repr(key))
    return errors

class ParserTests(unittest.TestCase):
    def test_parses_escaped_value(self):
        self.assertEqual(parse_catalog(r'"A" = "Quoted \"word\"";'), {'A': 'Quoted "word"'})
    def test_rejects_duplicate(self):
        with self.assertRaises(ValueError): parse_catalog('"A" = "a"; "A" = "b";')
    def test_rejects_trailing_garbage(self):
        with self.assertRaises(ValueError): parse_catalog('"A" = "a"; broken')
    def test_extracts_real_keys_not_symbols(self):
        self.assertEqual(literal_keys('Text("Ready"); Image(systemName: "gear"); L10n.text("Back")'), {'Ready', 'Back'})
    def test_shared_settings_components_keep_localization_coverage(self):
        source = 'SettingSupportingText("Help"); SettingPermissionRow(title: "Access", grantedTitle: "Ready") {}; SettingNumberField(title: "Time", unit: "minutes")'
        self.assertEqual(literal_keys(source), {'Help', 'Access', 'Ready', 'Time', 'minutes'})
    def test_diagnostic_job_names_are_keys_but_job_ids_are_not(self):
        source = 'scheduler.register(id: "calendar.clock", name: "Visible countdown", module: .calendar)'
        self.assertEqual(literal_keys(source), {'Visible countdown'})
    def test_interpolated_is_not_a_literal(self):
        self.assertEqual(literal_keys(r'Text("Value \(value)")'), set())
    def test_catalog_validation_rejects_missing_source_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Info.plist').write_bytes(plistlib.dumps({}))
            (root / 'View.swift').write_text('Text("Missing translation")')
            for locale in ('en', 'zh-Hans'):
                folder = root / f'Resources/{locale}.lproj'
                folder.mkdir(parents=True)
                (folder / 'Localizable.strings').write_text('"Known" = "Value";')
                (folder / 'InfoPlist.strings').write_text('')
            self.assertTrue(any('missing key' in error for error in validate(root)))
    def test_catalog_validation_rejects_placeholder_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Info.plist').write_bytes(plistlib.dumps({}))
            for locale, value in [('en', '%@ %lld'), ('zh-Hans', '%@ %@')]:
                folder = root / f'Resources/{locale}.lproj'
                folder.mkdir(parents=True)
                (folder / 'Localizable.strings').write_text('"Count" = "' + value + '";')
                (folder / 'InfoPlist.strings').write_text('')
            self.assertTrue(any('Format argument mismatch' in error for error in validate(root)))
    def test_arguments_are_semantic(self):
        self.assertEqual(placeholders('%@ %lld'), placeholders('%2$lld %1$@'))
        self.assertNotEqual(placeholders('%@ %lld'), placeholders('%@ %@'))


class HomeLocalizationTests(unittest.TestCase):
    """Guard the Home source boundary; native QA still verifies rendered text."""

    def setUp(self):
        self.source = (ROOT / 'Home/HomeScreenView.swift').read_text()

    def test_empty_state_preserves_localized_text(self):
        helper = self.source.split('private struct HomeEmptyState: View {', 1)[1]
        helper = helper.split('private enum HomeTypography', 1)[0]
        # String storage erases literal-key localization before Text sees it.
        for field in ('title', 'subtitle'):
            self.assertRegex(helper, rf'\blet {field}: Text\b')
            self.assertRegex(helper, rf'\b{field}\s*\n\s*\.font\(')

    def test_builtin_home_copy_uses_localization_entry_points(self):
        keys = {decode(match.group(1)) for match in CALL.finditer(self.source)}
        expected = {
            'No home modules enabled', 'Enable modules in Settings to show them here.',
            'Nothing coming up', 'Your schedule is clear for now.',
            'Fetching weather', 'Weather unavailable',
            'Getting your local conditions.', 'Allow location access to fetch local weather.',
            'No events scheduled today', '1 event coming up', '%d events coming up',
            'High', 'Low', 'Media', 'Upcoming event',
        }
        self.assertFalse(expected - keys, 'Home copy bypasses localization: ' + repr(sorted(expected - keys)))
        chinese = parse_catalog((ROOT / 'Resources/zh-Hans.lproj/Localizable.strings').read_text())
        for key in expected:
            self.assertNotEqual(chinese[key], key, key)

    def test_provider_and_user_content_remain_verbatim(self):
        # Providers already format localized messages; data may match a catalog
        # key by coincidence and must not be sent through a second lookup.
        for value in ('data.emptyTitle', 'data.emptySubtitle', 'data.title',
                      'data.subtitle', 'manager.weather.condition', 'manager.weather.locationName'):
            self.assertIn('Text(' + value + ')', self.source)
            self.assertNotIn('L10n.text(' + value, self.source)
        self.assertIn('Text(event.title ?? L10n.text("Upcoming event"))', self.source)


class IslandPresentationTests(unittest.TestCase):
    """Source contracts only; native QA must check colors and rendered strings."""

    def source(self, path):
        return (ROOT / path).read_text()

    def test_black_island_scopes_its_semantic_color_scheme(self):
        source = self.source('Views/IslandContainerView.swift')
        root_body = source.split('// MARK: - Surface', 1)[0]
        self.assertIn('.environment(\\.colorScheme, .dark)', root_body)
        self.assertIn('Color.black.opacity(0.98)', source)
        # Settings remains in a separate hosting root and follows macOS.
        for path in [ROOT / 'Application/NotchXApp.swift',
                     ROOT / 'Application/AppDelegate.swift',
                     *sorted((ROOT / 'Settings').glob('*.swift'))]:
            self.assertNotRegex(path.read_text(),
                r'\.(?:preferredColorScheme\(\.dark\)|environment\(\\\.colorScheme,\s*\.dark\))',
                str(path.relative_to(ROOT)))

    def test_summary_preserves_localized_text(self):
        source = self.source('Views/ExpandedView.swift')
        self.assertIn('let label: Text', source)
        self.assertRegex(source, r'\blabel\s*\n\s*\.font\(')
        for key in ('Battery', 'Music', 'Calendar', 'Shelf'):
            self.assertIn('label: Text("' + key + '")', source)

    def test_builtin_tab_titles_are_localized(self):
        source = self.source('Views/FullExpandedView.swift')
        self.assertIn('Text(L10n.text(tab.title))', source)
        self.assertIn('.help(L10n.text(tab.title))', source)

    def test_builtin_dynamic_copy_uses_stable_catalog_keys(self):
        expected = {
            'Views/FullExpandedView.swift': {'Unlock island', 'Lock island open'},
            'Modules/Teleprompter/TeleprompterCompactView.swift': {
                'No script', 'Starting', 'Playing · %d%%', 'Listening · %@', 'Waiting · %@'},
            'Modules/Shelf/ShelfViews.swift': {'Unpin', 'Pin'},
            'Modules/Connectivity/ConnectivityExpandedView.swift': {
                'Battery %d%%', 'Bluetooth device', 'Wi-Fi and Bluetooth are idle'},
        }
        chinese = parse_catalog((ROOT / 'Resources/zh-Hans.lproj/Localizable.strings').read_text())
        for path, keys in expected.items():
            source_keys = literal_keys(self.source(path))
            self.assertFalse(keys - source_keys, path + ': copy bypasses localization')
            for key in keys:
                self.assertNotEqual(chinese[key], key, key)

    def test_user_content_and_provider_messages_remain_verbatim(self):
        teleprompter = self.source('Modules/Teleprompter/TeleprompterCompactView.swift')
        self.assertIn('return error', teleprompter)
        self.assertIn('speech.lastSpokenText.prefix(12)', teleprompter)
        self.assertNotIn('L10n.text(error)', teleprompter)
        shelf = self.source('Modules/Shelf/ShelfViews.swift')
        for value in ('latest.displayName', 'item.displayName', 'item.subtitle'):
            self.assertIn('Text(' + value + ')', shelf)
            self.assertNotIn('L10n.text(' + value, shelf)
        connectivity = self.source('Modules/Connectivity/ConnectivityExpandedView.swift')
        for value in ('device.name', 'ssid', 'title', 'detail'):
            self.assertIn('Text(' + value + ')', connectivity)
            self.assertNotIn('L10n.text(' + value + ')', connectivity)


if __name__ == '__main__':
    if '--self-test' in sys.argv:
        unittest.main(argv=[sys.argv[0]])
    else:
        errors = validate()
        if errors:
            print('\n'.join(errors))
            sys.exit(1)
        print('PASS: parsed bilingual catalogs, literal source key coverage, and format-argument parity')
