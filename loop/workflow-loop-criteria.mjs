import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function assertString(value, name) {
  if (typeof value !== 'string' || !value.length || /^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/u.test(value)) throw new Error(`${name} must be a non-empty string`);
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new Error(`${name} contains an unpaired surrogate`);
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error(`${name} contains an unpaired surrogate`);
  }
}

export function criteriaCanonical(criteria) {
  if (!Array.isArray(criteria) || !criteria.length) throw new Error('targetCriteria must contain at least one criterion');
  const ids = new Set();
  const projection = criteria.map((criterion) => {
    for (const field of ['criterionId', 'description', 'validatorRef']) assertString(criterion?.[field], `criterion.${field}`);
    if (ids.has(criterion.criterionId)) throw new Error(`duplicate criterionId: ${criterion.criterionId}`);
    ids.add(criterion.criterionId);
    return { criterionId: criterion.criterionId, description: criterion.description, validatorRef: criterion.validatorRef };
  });
  return JSON.stringify(projection).replace(/[\u0085\u2028\u2029]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, '0')}`);
}

export function criteriaSha256(criteria) {
  return crypto.createHash('sha256').update(criteriaCanonical(criteria), 'utf8').digest('hex');
}

export async function runCriteriaVectors(vectorsPath) {
  const { readFileSync } = await import('node:fs');
  const vectors = JSON.parse(readFileSync(vectorsPath, 'utf8'));
  console.log(JSON.stringify(vectors.map((vector) => ({
    id: vector.id, canonical: criteriaCanonical(vector.criteria), sha256: criteriaSha256(vector.criteria),
  }))));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url) && process.argv[2] === '--vectors') {
  await runCriteriaVectors(process.argv[3]);
}
