#!/usr/bin/env python3
"""Verify macOS sticky reminder v2 and unchanged v1 consumer compatibility."""
import json
from pathlib import Path
from verify_pocket_contracts import SchemaEngine, VerifyError

ROOT = Path(__file__).resolve().parents[1]


def verify() -> int:
    contracts = ROOT / 'contracts/pocket'
    directory = contracts / 'v2/fixtures/sticky-reminders'
    schemas = {value['$id']: value for path in (contracts / 'v1').glob('*.schema.json')
               for value in [json.loads(path.read_text())]}
    engine = SchemaEngine(schemas)
    descriptor_schema = schemas['hoverpocket://schemas/capability-descriptor/v1']
    upsert = json.loads((directory / 'capability-descriptor.sticky-note-upsert.json').read_text())
    get = json.loads((directory / 'capability-descriptor.sticky-note-get.json').read_text())
    legacy = json.loads((contracts / 'v1/fixtures/valid/capability-descriptor.sticky-note-upsert.json').read_text())
    count = 0

    def check(value, schema, valid=True):
        nonlocal count
        try:
            engine.validate(value, schema, document=schema)
        except VerifyError:
            if valid:
                raise
        else:
            if not valid:
                raise AssertionError('Invalid or incompatible reminder fixture accepted')
        count += 1

    for descriptor in [upsert, get]:
        check(descriptor, descriptor_schema)
        assert descriptor['version'] == 2
        assert descriptor['availability'] == {'macos': 'available', 'windows': 'unavailable'}
        assert 'reminder' in descriptor['readback']['match']
    assert upsert['approvalPolicy'] == legacy['approvalPolicy'] == 'broker_policy'
    assert upsert['readback']['capabilityVersion'] == 2
    for case in json.loads((directory / 'inputs.json').read_text()):
        check(case['input'], upsert['inputSchema'], case['valid'])
        if case['valid']:
            check(case['input'], legacy['inputSchema'], case['name'] == 'preserve')
    legacy_output = {'noteId': '22222222-2222-4222-8222-222222222222', 'title': '資料', 'body': '資料を送る', 'updatedAt': '2027-01-15T08:00:00.000Z'}
    check(legacy_output, legacy['outputSchema'])
    for reminder in [None, {'scheduledAt': '2027-01-16T06:00:00.000Z', 'timeZone': 'Asia/Tokyo', 'acknowledgedAt': None}]:
        output = dict(legacy_output, reminder=reminder)
        check(output, upsert['outputSchema'])
        check(output, get['outputSchema'])
        check(output, legacy['outputSchema'], False)
    print(f'sticky_reminder_contracts=ok checks={count}')
    return count


if __name__ == '__main__':
    verify()
