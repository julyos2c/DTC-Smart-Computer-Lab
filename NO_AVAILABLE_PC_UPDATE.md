# CompuLab — No Available PCs (zero capacity) update

## Required behavior

- When one or more PCs remain for the requested lab/date/time, accept the
  reservation as **pending approval**, regardless of how many PCs were requested.
  The Edge grants no more than the currently available number on approval and
  sends the partial-allocation notification when necessary.
- When **zero PCs remain at submission**, display **No available PCs in
  [Lab] for the selected date and time. Please choose another schedule.**
  The new request is **not saved** (not Pending, not Waitlisted) and no access
  code is issued.
- When zero PCs remain **at approval** for a request that was submitted earlier,
  mark the existing request **Declined**, notify the linked requester and lab
  managers with **No available PCs**, and issue no official Session/code.
- For Cloud-to-Edge **create**, the Edge returns a rejected receipt with the
  same reason and creates no reservation. Cloud approval of an existing
  request returns a **rejected** receipt with an updated `status=declined`
  snapshot if the PCs were taken before approval.
- Keep a zero-PC edit from modifying an existing approved Session or pending
  request. This update does not automatically retry declined reservations.

## Example (10 available PCs, 9:00 AM–10:00 AM)

| Requester | Requested | Available before request | Result |
| --- | ---: | ---: | --- |
| A | 1 | 10 | 1 allocated after approval |
| B | 1 | 9 | 1 allocated after approval |
| C | 1 | 8 | 1 allocated after approval |
| D | 8 | 7 | 7 allocated, partial notification |
| E | 2 | 0 | **No available PCs** — rejected, not pending |

## Installation (Edge and Cloud)

1. Back up both applications and the Edge database, then stop Django and
   worker processes/services.
2. Apply the full ZIP or extract the patch ZIP into the project root that
   contains `manage.py`, preserving your `.env`, database, and virtualenv.
3. Activate your virtualenv and run `python manage.py check` and
   `python manage.py migrate` in each installation (the new zero-capacity
   change does **not** introduce additional migrations, but the earlier
   partial allocation package includes model migrations).
4. Restart the servers and Edge worker. Refresh the browser and test a
   full lab both on local forms and via a Cloud command.

## Tests

59 focused scheduling and Cloud reservation tests pass in a local SQLite
harness. A real MySQL database and deployed PC agents were not available
for end-to-end concurrency or hardware validation.

**Definition of available:** The booking calculation excludes PCs in
maintenance/issue status and subtracts approved overlapping allocations.
An otherwise healthy PC marked offline can still be counted for advance
reservations (it must be reachable at check-in); this behavior is unchanged.
