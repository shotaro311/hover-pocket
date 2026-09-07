#!/usr/bin/env python3
"""Validate v2 tool fixtures using the existing contract engine (no extra dependencies)."""
from __future__ import annotations
import copy
import json
from pathlib import Path
from verify_pocket_contracts import SchemaEngine, VerifyError, enforce_schema_policy

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / 'contracts/pocket/v2'

def main() -> None:
    schemas = {path.name: json.loads(path.read_text()) for path in CONTRACTS.glob('*.schema.json')}
    schemas_by_id = {schema['$id']: schema for schema in schemas.values()}
    for name, schema in schemas.items():
        enforce_schema_policy(schema, label=name, schemas_by_id=schemas_by_id, require_document_header=True)
    engine = SchemaEngine(schemas_by_id)
    count = 0
    def check(value, name, rejected=False):
        nonlocal count
        schema = schemas[name]
        try:
            engine.validate(value, schema, document=schema)
        except VerifyError:
            if not rejected: raise
        else:
            if rejected: raise AssertionError('Invalid fixture accepted: ' + name)
        count += 1
    fixtures = CONTRACTS / 'fixtures'
    for package in ['books', 'plants', 'plants-location', 'start-work']:
        directory = fixtures / package
        manifest = json.loads((directory / 'manifest.json').read_text())
        check(manifest, 'pocket-app.schema.json')
        for collection in manifest['collections'].values():
            check(json.loads((directory / collection['schema']).read_text()), 'pocket-collection.schema.json')
        for surface in manifest['surfaces']:
            if surface['kind'] == 'collection':
                check(json.loads((directory / surface['source']).read_text()), 'pocket-collection-surface.schema.json')
        for bad in ['hoverpocket.app/v1', 'hoverpocket.app/v3']:
            changed = copy.deepcopy(manifest); changed['apiVersion'] = bad
            check(changed, 'pocket-app.schema.json', True)
        changed = copy.deepcopy(manifest); changed['collections'] = {'../escape': {'schema': 'schema.json'}}
        check(changed, 'pocket-app.schema.json', True)
        changed = copy.deepcopy(manifest); changed['collections'] = {f'c{i}': {'schema': 'schema.json'} for i in range(17)}
        check(changed, 'pocket-app.schema.json', True)
        old = json.loads((ROOT / 'contracts/pocket/v1/pocket-app.schema.json').read_text())
        try: engine.validate(manifest, old, document=old)
        except VerifyError: count += 1
        else: raise AssertionError('v1-only consumers accepted v2')
    collection = json.loads((fixtures / 'books/collections/books.schema.json').read_text())
    for change in [lambda x: x.update(schemaVersion=True), lambda x: x.update(fields={}),
                   lambda x: x['fields'].update({f'x{i}': copy.deepcopy(next(iter(x['fields'].values()))) for i in range(33)}),
                   lambda x: next(iter(x['fields'].values())).update(type='remote'),
                   lambda x: next(iter(x['fields'].values())).update(required=1),
                   lambda x: next(iter(x['fields'].values())).update(choices=['invalid'])]:
        changed = copy.deepcopy(collection); change(changed); check(changed, 'pocket-collection.schema.json', True)
    document = json.loads((fixtures / 'collection-data.json').read_text()); check(document, 'pocket-collection-data.schema.json')
    for key, value in [('revision', True), ('revision', -1), ('formatVersion', 2)]:
        changed = copy.deepcopy(document); changed[key] = value; check(changed, 'pocket-collection-data.schema.json', True)
    changed = copy.deepcopy(document); changed['records'][0]['id'] = '../other'; check(changed, 'pocket-collection-data.schema.json', True)
    checkpoint = json.loads((fixtures / 'checkpoint.json').read_text()); check(checkpoint, 'pocket-tool-checkpoint.schema.json')
    for key, value in [('createdAt', 1), ('createdAt', '2026-09-06T12:00:00+09:00'), ('kind', 'failed'), ('byteCount', -1)]:
        changed = copy.deepcopy(checkpoint); changed[key] = value; check(changed, 'pocket-tool-checkpoint.schema.json', True)
    payload = {'formatVersion': 2, 'state': {}, 'collections': {'items': document}}
    check(payload, 'pocket-tool-backup-data.schema.json')
    changed = copy.deepcopy(payload); changed['collections']['items']['revision'] = -1
    check(changed, 'pocket-tool-backup-data.schema.json', True)
    print(f'PASS pocket tools v2 contracts: {count} schema and v1 rejection checks')

if __name__ == '__main__': main()
