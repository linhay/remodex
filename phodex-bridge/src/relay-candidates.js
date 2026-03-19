// FILE: relay-candidates.js
// Purpose: Normalizes relay candidates and rotates through them for reconnect fallback.
// Layer: CLI helper
// Exports: buildRelayCandidateList, createRelayCandidateRotator

function buildRelayCandidateList(primaryRelayUrl, relayCandidates = []) {
  const mergedCandidates = [...(Array.isArray(relayCandidates) ? relayCandidates : []), primaryRelayUrl];
  const seen = new Set();
  const result = [];

  for (const candidate of mergedCandidates) {
    const normalized = normalizeRelayBaseUrl(candidate);
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    result.push(normalized);
  }

  return result;
}

function createRelayCandidateRotator(candidates, sessionId) {
  const normalizedCandidates = Array.isArray(candidates) ? candidates.filter(Boolean) : [];
  if (!normalizedCandidates.length) {
    throw new Error("At least one relay candidate is required.");
  }

  const normalizedSessionId = typeof sessionId === "string" ? sessionId.trim() : "";
  if (!normalizedSessionId) {
    throw new Error("A relay session id is required.");
  }

  let index = 0;

  function currentBaseUrl() {
    return normalizedCandidates[index];
  }

  function currentSessionUrl() {
    return `${currentBaseUrl()}/${normalizedSessionId}`;
  }

  function advance() {
    if (normalizedCandidates.length === 1) {
      return currentBaseUrl();
    }
    index = (index + 1) % normalizedCandidates.length;
    return currentBaseUrl();
  }

  function hasFallbacks() {
    return normalizedCandidates.length > 1;
  }

  return {
    currentBaseUrl,
    currentSessionUrl,
    advance,
    hasFallbacks,
  };
}

function normalizeRelayBaseUrl(value) {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return "";
  }
  return trimmed.replace(/\/+$/, "");
}

module.exports = {
  buildRelayCandidateList,
  createRelayCandidateRotator,
};
