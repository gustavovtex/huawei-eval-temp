# Feature Specification: Tokenized Saved Cards on Checkout V6

**Feature Branch**: `001-tokenized-saved-cards`
**Created**: 2026-06-10
**Status**: Draft
**Input**: User description: "Tokenized saved cards support on Checkout V6 UI (vcs.checkout-ui). Enable shoppers to pay with tokenized/saved credit cards using accountId-based authorization, optional CVV based on useCvvForAuthorization, and zero regression for non-tokenized flows. Backend (PPP, Gateway, CTV) already in production; this is exclusively a UI-layer task. Companion spec exists in card-ui repo (specs/001-tokenized-saved-cards)."

## Context

This spec implements the **PRD: Tokenization on Checkout V6** (@fabio.daneluzzi, Apr 2026) and consolidates the prior analysis in `tokenization-task/spec/` (tokenization.md, tokenization-clarification.md, card-ui-analysis.md) with the decisions updated after review comments from @jeffersontuc:

| Decision | Previous | Current (this spec) |
|---|---|---|
| Unauthenticated user with saved card | Option A: redirect to login | **Option D: in-page VTEX ID modal** — reuse the existing v6 login UX (`vtexid.start()` / `showAuthentication` pattern), avoiding redirect friction |
| Feature flag | Hardcoded account allowlist in UI | **No UI flag — data-driven by the API/orderForm** (per @carolina.almeida suggestion). The API decides whether cards are tokenized; the UI reacts to `availableAccounts` data, mirroring the existing PMA precedent (`availableAssociations` → `ChkToggle`) |
| `cardOrigin` location | Inside `fields` (TBD) | **Top-level on the payment object** (`paymentData.payments[N].cardOrigin`), following FastCheckout: it is persisted to the orderForm, never sent to the Gateway inside `fields` |
| CVV rendering ownership | card-ui decides (likely) | **Confirmed by Jeff**: card-ui decides based on `availableAccounts` data broadcast by checkout-ui |

**Revision 2026-06-11 (supersedes the original "conscious divergence")**: the first version of this spec prompted login for **any** saved-card selection while `loggedIn: false` (superset of REQ-09), because the UI cannot distinguish tokenized cards upfront while unauthenticated. Live tests on `fdtest` (research.md R7) showed that superset to be both unnecessary and harmful: (a) the Checkout API itself rejects the selection of a CVV-less tokenized card while unauthenticated — `attachments/paymentData` returns **403 `CHK003` "Acesso negado"** — providing a reactive, per-card signal; (b) legacy saved cards are accepted (200) and their identified-not-logged + CVV purchase flow remains valid server-side, so the preemptive prompt would break SmartCheckout repurchase in stores without tokenization, violating REQ-04. The auth gate is therefore **reactive**: it triggers on the `CHK003` rejection, restoring the literal REQ-09 scope. **Confirmed** (Slack thread vtex.slack.com/archives/C1FRE8V9A/p1779306842178329): `CHK003` on selection is a stable contract, triggered for `useCvvForAuthorization: false` entries.

Out of scope (unchanged, matches PRD): combining mode / card-ui v2 (confirmed unused by @carolkrroo), `cardLabel` display, FastCheckout-style CVV modal, network tokens, provider iframes at place order, visual/UX redesign of the saved-cards list.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pay with a saved tokenized card (Priority: P1)

A returning, authenticated shopper sees their saved cards, selects one, and completes the purchase. Authorization is sent with the `accountId` reference only — no PAN data.

**Why this priority**: This is the core value of the feature (~6pp authorization rate improvement per Adyen data). Without it nothing else matters.

**Independent Test**: With an orderForm containing `availableAccounts`, select a saved card and complete checkout; verify the Gateway payload contains `fields.accountId` and no PAN fields, and that the order is placed.

**Acceptance Scenarios**:

1. **Given** an authenticated shopper with tokenized cards in `orderForm.paymentData.availableAccounts`, **When** they select a saved card and submit, **Then** the payment sent to the Gateway references `accountId` and contains no `cardNumber`, `dueDate`, `holderName`, or `document`.
2. **Given** a payment carrying `accountId`, **When** the transaction response (`merchantTransactions`) is merged into the payment during assembly (`checkout.coffee` ~line 1084, `_.extend`), and the response omits `accountId` (the real `merchantSellerPayments` shape), **Then** the original `accountId` (top-level and `fields.accountId`) is preserved.
3. **Given** a transaction response that carries a valid (non-null) `accountId`, **When** merge happens, **Then** the response value wins (normal merge behavior).
4. **Given** the provider updates the token during the authorization flow (e.g., LVT → HVT — PRD REQ-06, BDD scenario "Token Update During Authorization Flow"), **When** the transaction response carries the updated reference, **Then** the assembled payment honors the update and no error surfaces to the shopper.

---

### User Story 2 - CVV optional based on useCvvForAuthorization (Priority: P1)

A shopper selecting a saved card is only asked for CVV when the provider requires it (`useCvvForAuthorization: true` or absent). When `false`, no CVV is collected and `fields.validationCode` is omitted.

**Why this priority**: CVV-optional is the main UX differentiator of tokenization and a P1 alongside US1; it requires the checkout-ui → card-ui data contract to be in place.

**Independent Test**: Broadcast an orderForm whose `availableAccounts` entries carry `useCvvForAuthorization` variants and verify the payload includes/omits `validationCode` accordingly.

**Acceptance Scenarios**:

1. **Given** a saved card with `useCvvForAuthorization: false`, **When** the shopper selects it and submits, **Then** `fields.validationCode` is absent from the payload and submit validation passes without CVV.
2. **Given** a saved card with `useCvvForAuthorization: true` or with the property missing, **When** the shopper selects it, **Then** CVV is required and validated before submit (safe default).
3. **Given** any orderForm update, **When** checkout-ui broadcasts `orderFormUpdated.vtex` to the card-ui iframe, **Then** `availableAccounts` entries retain `useCvvForAuthorization` unmodified (full orderForm serialization — no stripping).
4. **Given** a new card (no `accountId`), **When** the shopper fills the form, **Then** CVV is always required (unchanged behavior).

---

### User Story 3 - Save a new card as tokenized (Priority: P2)

A shopper enters a new card with "save my card" checked (`savePaymentData: true`). The purchase completes and the card is stored tokenized for future purchases, with `cardOrigin: 'shopper'` recorded.

**Why this priority**: Required for the token lifecycle to start, but the purchase itself already works today; only the `cardOrigin` marker is new on this repo's side.

**Independent Test**: Complete a purchase with a new card and `savePaymentData: true`; verify the payment object carries top-level `cardOrigin: 'shopper'`; verify it is absent when `savePaymentData: false` or when paying with a saved card.

**Acceptance Scenarios**:

1. **Given** a new card and `savePaymentData: true`, **When** the payment is assembled, **Then** the payment object carries top-level `cardOrigin: 'shopper'` (not inside `fields`).
2. **Given** a new card and `savePaymentData: false`, **When** the payment is assembled, **Then** `cardOrigin` is absent.
3. **Given** a saved card (`accountId` present), **When** the payment is assembled, **Then** `cardOrigin` is not added by checkout-ui.

---

### User Story 4 - Unauthenticated shopper selecting a CVV-less tokenized card (Priority: P2) — *revised 2026-06-11*

An identified-but-not-authenticated shopper (`canEditData: false`, `loggedIn: false`) selects a saved card whose selection the Checkout API rejects with **403 `CHK003`** (CVV-less tokenized card). Instead of the current production behavior (unhandled error → infinite loading), checkout-ui reacts: releases the loading state and prompts the existing in-page VTEX ID login modal. After authenticating, the orderForm refreshes (now including `useCvvForAuthorization`/`isCardToken`) and the shopper continues without losing checkout context. Saved cards whose selection the API accepts (legacy cards — and tokenized CVV-required, if accepted) proceed exactly as today, with no login prompt.

**Why this priority**: Fixes a live production hang (research.md R7 finding 5) and prevents the guaranteed authorization error for CVV-less tokenized cards, while keeping the SmartCheckout identified-not-logged repurchase flow intact for legacy cards (REQ-04).

**Independent Test**: Simulate a `CHK003` 403 response from the paymentData attachment with a saved card selected; verify loading is released, `vtexid.start()` is invoked (same pattern as `showAuthentication`), and that after `authenticatedUser.vtexid` the orderForm is refreshed and re-broadcast to card-ui. Verify a 200 selection triggers no modal.

**Acceptance Scenarios**:

1. **Given** `orderForm.loggedIn: false` and a paymentData attachment that fails with 403 `CHK003`, **When** checkout-ui processes the failure, **Then** the loading state is released and the VTEX ID modal is opened via the existing `vtexid.start()` pattern (no full-page redirect, no infinite loading).
2. **Given** `orderForm.loggedIn: false` and a paymentData attachment that succeeds (200 — legacy saved card), **When** checkout-ui processes the response, **Then** NO login modal is triggered and the flow proceeds exactly as today (zero regression — REQ-04).
3. **Given** the shopper completes login in the modal, **When** `authenticatedUser.vtexid` fires, **Then** `checkout.update()` refreshes the orderForm and the card-ui iframe receives the updated `availableAccounts` (with `useCvvForAuthorization`/`isCardToken`).
4. **Given** the shopper completes login and the refreshed `availableAccounts` still contains the card they had selected, **When** the payment step re-renders, **Then** the same card remains/is re-selected and the shopper can complete the purchase without re-picking it (PRD REQ-09 acceptance criteria). NOTE: because the rejected selection was never persisted server-side (403), re-selection requires re-sending the attachment after login — the card-ui re-hydration fallback (`firstEligibleSavedCard`) is NOT sufficient on its own.
5. **Given** the shopper completes login and the previously selected card is NOT present in the refreshed `availableAccounts`, **When** the payment step re-renders, **Then** the selection is cleared safely (no stale `accountId` may survive in `paymentData.payments`).
6. **Given** the shopper dismisses the modal without logging in, **When** they attempt to submit with the rejected saved card still selected locally, **Then** submission is blocked and the modal is shown again (same contract as payment systems with `requiresAuthentication`).
7. **Given** `checkout.userType() is 'callCenterOperator'`, **When** a `CHK003` rejection occurs, **Then** the login modal is NOT triggered (parity with the existing `showAuthentication` exemption) and a non-blocking error message is shown instead.

---

### User Story 5 - View and remove tokenized cards from the saved-cards list (Priority: P2)

A shopper sees their tokenized cards in the saved-cards list (bin, last 4 digits, brand, expiration — current V6 layout) and can remove any of them. Removal unlinks the card in Profile System and deletes the token in CTV through the existing delete flow (PRD REQ-03, Must have).

**Why this priority**: Must-have in the PRD MVP — shoppers need control over stored payment methods. Listing already works (tokenized cards arrive as regular `availableAccounts` entries); the removal path has a known gap: card-ui emits `removeCardToken.vtex`, which checkout-ui does not handle today (only `removeCardAccount.vtex`).

**Independent Test**: With tokenized cards in `availableAccounts`, remove one from the card-ui list; verify the corresponding delete call is made and the orderForm refresh no longer lists the card.

**Acceptance Scenarios**:

1. **Given** tokenized cards in `availableAccounts`, **When** the saved-cards list renders, **Then** each entry shows bin/last-4/brand/expiration exactly as today (no layout change — `cardLabel` out of scope).
2. **Given** the shopper removes a saved card backed by `accountId`, **When** card-ui emits `removeCardAccount.vtex`, **Then** checkout-ui calls the existing `vtexjs.checkout.removeAccountId` flow and the card disappears after the orderForm refresh (existing behavior — must be verified for tokenized entries).
3. **Given** the shopper removes a saved card whose entry is token-backed, **When** card-ui emits `removeCardToken.vtex`, **Then** checkout-ui handles the message and the token is deleted through the existing delete flow (closes today's unhandled-message gap).
4. **Given** a B2B account with tokenized cards imported via Buyer Portal / CTV APIs (PRD REQ-05, BDD scenarios 1, 3, 6), **When** the shopper opens the payment step authenticated, **Then** those cards are listed and selectable like any other `availableAccounts` entry (data-driven — no import-specific logic in the UI).

---

### Edge Cases

- Transaction response omits `accountId` AND original payment had no `accountId` (new card): merge proceeds normally, nothing to preserve.
- `availableAccounts` entry without `useCvvForAuthorization` (legacy non-tokenized saved card): CVV required — identical to today's behavior.
- Saved card deleted in Profile System but still cached in the rendered list: Gateway rejects; generic payment error shown (error UX details tracked as open question #8 in clarifications).
- Multiple payments (split) where only one carries `accountId`: preservation logic must be applied per payment, not globally.
- orderForm refresh after login: if the previously selected card still exists, selection is preserved (US4 scenario 4); if it no longer exists, selection is cleared (US4 scenario 5).
- Non-`CHK003` attachment failures (network errors, other API errors): loading must still be released (FR-014), without triggering the login modal.
- `CHK003` arriving for an authenticated session (unexpected — would indicate a backend contract change): release loading, show generic payment error, log diagnostics; do not loop the login modal.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001** *(REVISED 2026-06-11)*: System MUST preserve top-level `accountId` and `fields.accountId` on each payment through the `merchantTransactions` merge during payment assembly. Satisfied by plain `_.extend`: the real `merchantSellerPayments` shape omits `accountId`, so the merge keeps the original. The earlier preserve/restore logic (and `mergeMerchantIntoPayment`) assumed the source could carry `accountId: null` — a risk that did not materialize — and was removed.
- **FR-002** *(REVISED 2026-06-11)*: System MUST NOT send PAN fields (`cardNumber`, `dueDate`, `holderName`, `document`) to the Gateway when the payment carries `accountId`. Satisfied structurally: a saved-card selection references the card by `accountId` and carries only `fields: { accountId, validationCode }` (research.md), never raw PAN — and card-ui owns card-data handling. The redundant checkout-ui defensive strip (`stripPanFields`) was removed.
- **FR-003**: System MUST broadcast the full `availableAccounts` data — including `useCvvForAuthorization` when present — to the card-ui iframe via the existing `orderFormUpdated.vtex` postMessage (no contract change).
- **FR-004**: System MUST validate submit-readiness for saved cards according to `useCvvForAuthorization`: require CVV when `true` or missing; accept absence of CVV when `false` (defensive validation; card-ui is the primary gate).
- **FR-005**: System MUST add top-level `cardOrigin: 'shopper'` to the payment when (a) it is a new card (no `accountId`) and (b) `savePaymentData` is `true`; and MUST NOT add it otherwise.
- **FR-006** *(revised 2026-06-11)*: System MUST handle the **403 `CHK003`** rejection of the paymentData attachment (`attachments/paymentData`) for a saved-card selection: release the loading state and trigger the existing VTEX ID in-page modal (`vtexid.start()` with the payment-step title, following the `showAuthentication` pattern), except for `callCenterOperator` (non-blocking error message instead). System MUST NOT trigger the modal preemptively for saved-card selections the API accepts (200) — legacy identified-not-logged flows remain untouched (REQ-04).
- **FR-007**: System MUST block order submission while the saved-card-authentication condition of FR-006 is unresolved (selection rejected with `CHK003` and shopper still unauthenticated), reopening the modal on submit attempts.
- **FR-008**: System MUST refresh the orderForm (`checkout.update()`) upon `authenticatedUser.vtexid` and re-broadcast it to the card-ui iframe (existing behavior — must be verified to cover the saved-card path).
- **FR-009** *(REVISED 2026-06-11 — superseded by FR-015)*: ~~System MUST NOT introduce a UI-side feature flag for tokenization~~. Original rationale (API-side per-seller control) kept for history; the team decided to ADD an in-code UI flag as an extra safety layer for the production rollout — see FR-015.
- **FR-015** *(added 2026-06-11)*: System MUST gate every tokenization behavior behind an in-code feature flag (`TOKENIZED_SAVED_CARDS` in `src/script/feature-flags.js`, FastCheckout pattern: `boolean | string[]` account allowlist matched against `vtex.accountName`). With the flag off, behavior MUST be identical to master. The three gated integration points — all in `src/script/payment/payment-data-vm.coffee` — are: (1) `cardOrigin` marking in `getAllPaymentsAndGiftsForRnB` (FR-005); (2) reactive CHK003/FR-006 and FR-014 handlers wired in `sendAttachment` and `adjustPayments`; (3) CVV submit-readiness check in `savedCardsSubmitReady` (FR-004). `checkout.coffee` has no tokenization code (functions `mergeMerchantIntoPayment`, `stripPanFields` were removed; `applyCardOrigin` lives in `tokenization-utils.js` and is called from `payment-data-vm.coffee` behind gate (1)). The companion flag lives in card-ui (`src/utils/featureFlags.js`) and must list the same accounts. Rollout: empty allowlist → pilot account(s) → `true` → flag removal.
- **FR-010**: System MUST keep all existing non-tokenized payment flows byte-identical in behavior (zero regression): new card without save, legacy saved cards without `useCvvForAuthorization`, gift cards, promissories, etc.
- **FR-011** *(REVISED 2026-06-11)*: Tokenized-card removal MUST flow through the EXISTING `removeCardAccount.vtex` → `removeAccountId` → `POST /paymentAccount/{id}/remove` contract (PRD REQ-03). Rationale: tokenized cards are `availableAccounts` entries carrying `accountId` (`isCardToken: true`, research.md R7) and card-ui routes their deletion by `accountId`; `removeCardToken.vtex` only fires for tokenId-only entries (`availableTokens`), which no known flow produces. No new endpoint is needed — the same `/paymentAccount/{id}/remove` already used for legacy saved cards is reused for tokenized cards; no new backend work required. The originally shipped handler (which deduced a `/paymentToken/{id}/remove` URL by analogy) was removed; `removeCardToken.vtex` remains intentionally unhandled, as on master. Open item (T038a, non-blocking): confirm with API team whether any flow produces tokenId-only `availableTokens` entries.
- **FR-012**: System MUST honor provider token updates returned during the authorization flow (PRD REQ-06) — covered structurally by FR-001's merge semantics (valid response values win) and verified by a dedicated test against the "Token Update During Authorization Flow" BDD scenario.
- **FR-013**: System MUST preserve the shopper's saved-card selection across the post-login orderForm refresh whenever the refreshed `availableAccounts` still contains the selected card (PRD REQ-09); otherwise the selection MUST be cleared safely. NOTE (revision 2026-06-11): for `CHK003`-rejected selections the attachment was never persisted server-side — preservation requires re-sending the selection after login, not just orderForm re-hydration.
- **FR-014** *(added 2026-06-11)*: System MUST NOT leave the payment step in a loading state when the paymentData attachment fails — any error response releases the loading state (fixes the production hang documented in research.md R7 finding 5; `CHK003` additionally follows FR-006).

### Key Entities

- **availableAccount**: entry of `orderForm.paymentData.availableAccounts`; key attributes: `accountId`, `paymentSystem`, masked `cardNumber`, `useCvvForAuthorization` and `isCardToken` (only present when authenticated — research.md R7), `expirationDate` (authenticated only), `bin` (real 6-digit when authenticated; masked 32-char hash when not — MUST be treated as an opaque string, never as a tokenization marker).
- **CHK003 rejection**: `{ error: { code: "CHK003", message: "Acesso negado" } }` with HTTP 403 returned by `attachments/paymentData` when an unauthenticated session selects a CVV-less tokenized card; the reactive trigger of FR-006. Contract confirmed as stable — see Slack thread vtex.slack.com/archives/C1FRE8V9A/p1779306842178329.
- **payment**: entry of `paymentData.payments` / assembled `paymentsArray`; key attributes: `accountId` (top-level), `fields.accountId`, `fields.validationCode`, `cardOrigin` (top-level, write-only marker for new saved cards).
- **merchantTransaction**: per-merchant response of `startTransaction`; merge source during payment assembly; may carry `accountId: null`.
- **orderForm auth state**: `loggedIn`, `canEditData`, `userType` — gates the authentication modal and the presence of `useCvvForAuthorization`.

## Constitution Compliance

Per `.specify/memory/constitution.md`:

- All changes touch `src/script/payment/` and/or `src/script/orderform/` — **human review required on every change**.
- Tests MUST be `test/*-test.js` (Jest 27, hyphen naming). New logic in payment assembly and validation requires happy-path + failure tests.
- The Component Event API and the card-ui postMessage contract (`orderFormUpdated.vtex`, `updatePayments.vtex`, `requireAuthentication.vtex`, ...) are public contracts — **no renames/shape changes**; this feature only adds data that already flows through the serialized orderForm.
- New code in `.js`/`.ts`; in-place edits to existing `.coffee` files are allowed where that is the smallest correct change (payment assembly in `checkout.coffee` qualifies).
- E2E tests live in `vtex/checkout-ui-tests` (out of this repo's scope).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A shopper with a tokenized saved card completes a purchase without typing card data (CVV at most), with authorization referencing `accountId` only.
- **SC-002**: 100% of payment-assembly merge scenarios (accountId preservation matrix) covered by unit tests and passing.
- **SC-003**: Zero failures introduced in the existing V6 regression suite (all pre-existing Jest tests green).
- **SC-004**: No payload captured in tests/staging contains PAN fields together with `accountId`.
- **SC-005**: An unauthenticated selection rejected with `CHK003` never results in an infinite loading state nor a Gateway authorization error — the login modal intercepts it; selections accepted by the API (legacy cards) never see the modal.
- **SC-006**: Authorization rate on saved-PPT-card purchases in V6 does not regress vs. legacy saved-card purchases over the same period (PRD Cond-2, adapted). Dedicated PPT-vs-legacy dashboards (PRD REQ-07) are **MLP, not MVP** — tracked as open question #9.
- **SC-007**: A shopper can remove a tokenized card from the saved-cards list and it no longer appears after the orderForm refresh (PRD REQ-03).
- **SC-008**: After the login prompt, the shopper returns with the same card selected and completes the purchase (PRD REQ-09).

## Dependencies & Coordination

- **card-ui companion spec**: `card-ui/specs/001-tokenized-saved-cards/spec.md` — CVV conditional rendering/validation, complete PAN removal, auth trigger emission. Cross-repo PRs must be linked (card-ui constitution Principle III).
- Backend (PPP v2.0.0, Gateway tokenization, CTV): already in production — no changes required.
- Open questions inherited from clarifications (non-blocking for planning): #7 testing strategy with @thaynan.nunes, #8 error-handling UX, #9 observability metrics, #10 docs.

## PRD Traceability

PRD: "Tokenization on Checkout V6" (@fabio.daneluzzi). All Must-have MVP requirements mapped:

| PRD | Phasing | Coverage in this spec | Notes |
|---|---|---|---|
| REQ-01 (new card → token) | MVP | US3 (cardOrigin) + FR-005; E2E via Postman collection | Token issuance is backend; UI marks save intent. E2E ownership: open question #7 |
| REQ-02 (pay with saved tokenized card) | MVP | US1, FR-001/FR-002 | Payload parity with FastCheckout (same `accountId`) |
| REQ-03 (view/remove tokenized cards) | MVP | US5, FR-011, SC-007 | Closes the `removeCardToken.vtex` handler gap |
| REQ-04 (zero regression + per-seller flag) | MVP | FR-009, FR-010, SC-003 | Per-seller control is API-side (see FR-009) |
| REQ-05 (B2B imported cards selectable) | MVP | US5 scenario 4 | Data-driven; BDD scenarios 1, 3, 6 |
| REQ-06 (token update during auth) | MVP | US1 scenario 4, FR-012 | Merge semantics: valid response values win |
| REQ-07 (dedicated metrics) | MLP | SC-006 note, open question #9 | Not MVP |
| REQ-08 (keep V6 CVV experience) | MVP | US2 + card-ui spec US1 | Inline CVV, no FastCheckout modal |
| REQ-09 (login prompt, same card after) | MVP | US4 scenarios 1-7, FR-006, FR-007, FR-013, FR-014, SC-008 | Literal scope restored (revision 2026-06-11): reactive prompt on `CHK003` rejection only |
