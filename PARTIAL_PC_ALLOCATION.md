# CompuLab — Shared PC Reservation & Partial Allocation

## New behavior

Reservations for the same lab, date, and overlapping time share PC capacity.
**If at least one PC is available**, a new request is accepted for approval even
when the requester asks for more PCs than remain. Pending requests do not hold
capacity; the Edge Server finalizes the allocation at approval.

**If zero PCs are available**, the form shows **No available PCs** and **does not
save a new pending request**. The Edge rejects Cloud create commands with the
same clear reason, and no reservation code or Session is created.

When Admin/Lab In-Charge (or a Cloud reservation command) approves the request:

1. The system counts schedulable lab PCs, excluding `maintenance` and `issue`
   PCs. A PC that is simply `offline` can be reserved for a **future** class
   because it may be switched on before the reservation; actual check-in still
   requires an available, reachable PC/agent.
2. Subtracts the **confirmed allocations** of all approved sessions that overlap
   `start < other_end AND end > other_start`.
3. Grants `min(requested, free)` PCs under the Edge Server's transaction lock.
4. Saves `SessionRequest.pcs_allocated` and `Session.pcs_allocated`.
5. Preserves the original requested count: `SessionRequest.student_count` for
   ordinary requests, `SessionRequest.pcs_requested` for walk-in/override.
   `Session.student_count`/`pcs_requested` are capped for check-in enforcement.
6. Notifies the linked requester and relevant lab staff if the allocation is
   partial. Notification reports requested, allocated and unavailable counts.
7. If **zero** PCs remain at approval time (capacity taken since submission),
   the existing pending request is marked `declined`, with a **No available PCs**
   notification. No reservation code or official Session is created. Users must
   submit a *new* request after capacity becomes available.
8. If a pending request is edited to a fully booked time, the edit is blocked;
   the originally saved request is not modified.

### Example

A lab has 10 schedulable PCs, all reservations from 09:00 to 10:00:

| Request | PCs requested | PCs allocated | Result |
| --- | ---: | ---: | --- |
| A | 1 | 1 | Approved |
| B | 1 | 1 | Approved |
| C | 1 | 1 | Approved |
| D | 8 | 7 | Approved — partial allocation notification |
| E | 2 | 0 | Rejected: No available PCs; not saved as pending |

The Cloud Server's **create/edit** request remains provisional until the Edge
processes it; Cloud **approve** commands invoke the same capacity calculation
and return the final allocation in their synchronized reservation snapshot
(`requested_pcs`, `pcs_allocated`, `status`). A Cloud **create** request for a
full slot returns a `rejected` receipt with `No available PCs` and creates no
new reservation. If a Cloud **approve** finds that PCs ran out since submission,
it returns a `rejected` receipt with the reservation snapshot showing
`status=declined` and an explicit no-capacity message.

## Setup on the Windows Edge Server

1. **Back up** your database and existing application; stop the CompuLab
   workers/services before replacing source files.
2. Copy the patched files into the **existing** CompuLab project, preserving
   your environment configuration and local database. The complete source
   ZIP intentionally excludes `.env`, virtual environments, database files,
   and `.git` history. A smaller patch-only ZIP is also provided.
3. Activate your environment and run:

   ```powershell
   .\.venv\Scripts\Activate.ps1
   python manage.py migrate
   python manage.py check
   ```

4. Restart the Edge Server and worker. The Cloud Server application should
   also be updated to include the new notification and Cloud snapshot fields
   if separate deployments use this same shared codebase.
5. Test two overlapping requests, partial allocation, rejection of a new
   0-free-PC request, and decline of a request that loses capacity before approval.

## Technical notes

- New migrations: `scheduling/0023_partial_pc_allocation.py`,
  `scheduling/0024_alter_session_pcs_requested_and_more.py`, and
  `notifications/0011_reservation_allocation_type.py`.
- 0023 backfills previously approved sessions with an allocated count based
  on their existing check-in capacity.
- The existing `schedule_write_lock` serializes local `/schedule/` POSTs and
  Edge-executed Cloud commands against the same laboratory rows on a
  transactional database such as MySQL. SQLite is for functional tests,
  **not** verifying production concurrency.
- Quantity is allocated; **specific PC IDs are not pre-assigned**. Actual
  machine choice and agent connectivity are handled at check-in.
- Zero-PC requests are **not waitlisted** and are not automatically retried.
  Users must select another time or try again after a cancellation. Email
  requires a registered address, and this patch does not modify a running
  deployment by itself.

## Verification

Django's check, migrations check, and **59 scheduling + cloud reservation tests**
passed on an isolated SQLite test configuration. A full 201-test suite had one
pre-existing, unrelated failure in
`labs.test_agent_auth.SystemStatusSecretSummaryTests.test_status_page_shows_secret_migration`,
which is reproduced on the original source. MySQL/PC-agent live deployment
was not available to test.
