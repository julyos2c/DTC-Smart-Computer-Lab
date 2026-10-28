# Cloud remote PC control

Daloy: cloud Django admin -> durable command queue -> outbound HTTPS poll ng edge worker -> existing LAN PC agent -> result pabalik sa cloud.

## Ilagay ang updated code

1. I-backup muna ang database at application folder ng cloud at edge.
2. Extract ang source ZIP sa staging folder. I-update ang application code sa **parehong cloud at edge**. Panatilihin ang kani-kanilang existing `.env`, database, uploads, at agent configuration. Hindi kasama ang tunay na `.env`, virtual environment, logs, o database sa source package na ito.
3. Gamitin ang existing supported Python environment/dependencies ng project. Walang bagong third-party dependency ang remote-control feature. Ang verification dito ay gumamit ng Python 3.13 at Django 5.0.14; gumamit ng interpreter na compatible sa installed Django version.
4. Sa parehong installation, patakbuhin:

```powershell
python manage.py migrate
python manage.py check
```

May bagong migration: `cloud_receiver/0002_commandreceipt_remotecommand.py`. Kailangan ito sa parehong server: cloud command queue sa cloud; local execution receipts sa edge.

## Cloud configuration

HTTPS ang cloud URL. Kung TLS proxy ang gamit, i-configure ang existing `DJANGO_BEHIND_PROXY=True` setting at siguraduhing trusted proxy lang ang nagse-set ng forwarded headers.

Kung wala pang campus API key, patakbuhin sa private terminal:

```powershell
python manage.py cloud_receiver_key --site dtc-main
```

Kopyahin ang generated settings sa tamang installation. Huwag ilagay ang key sa source code o ipakita sa public screenshots.

Cloud `.env`:

```dotenv
CLOUD_RECEIVER_ENABLED=True
CLOUD_REMOTE_CONTROL_ENABLED=True
CLOUD_RECEIVER_SITES=dtc-main:<generated SHA-256 digest>
EDGE_REMOTE_CONTROL_ENABLED=False
COMPULAB_BACKGROUND_TASKS=False
```

Huwag literal na gamitin ang placeholder. Kung configured na ang sync key, puwedeng gamitin ang existing matching key/digest. Panatilihin ang existing cloud cron worker para sa email kung ginagamit ito; hindi kailangan ng cloud background worker para ihatid ang commands.

Restart ang cloud web application.

## Edge configuration

Campus/edge `.env`:

```dotenv
CLOUD_SERVER_URL=https://your-cloud-domain.example
CLOUD_SYNC_SITE_ID=dtc-main
CLOUD_SYNC_API_KEY=<matching generated raw API key>
EDGE_REMOTE_CONTROL_ENABLED=True
CLOUD_REMOTE_CONTROL_ENABLED=False
COMPULAB_BACKGROUND_TASKS=False
```

Restart ang edge web service at patakbuhin ang **isang supervised edge worker service**:

```powershell
python manage.py run_worker
```

Ang long-running worker ay nagpo-poll kada loop (nominally 5 seconds; maaaring humaba habang may ibang jobs). Compatible rin ang existing in-process worker mode, pero ang dedicated service ang setup sa itaas. Hindi kailangang mag-port-forward mula internet papunta sa school. Ang existing edge-to-agent LAN/firewall access sa port 5555 ay kailangan pa rin.

## Paggamit

1. Mag-login sa cloud `/admin/` gamit ang active, approved/verified **staff admin** o superuser. Kung walang ganitong account, gamitin ang existing account administration o `python manage.py createsuperuser`.
2. Buksan ang **Cloud receiver -> Remote commands -> Add**.
3. Ilagay ang configured `site_id`, ang **numeric database primary key** ng campus PC, at action: lock, unlock, shutdown, o restart. Ang numeric key ay makikita sa local PC edit URL; hindi ito ang display label na `PC-01`.
4. Expiry default: 2 minutes; maximum sa form: 5 minutes. I-save ang command.
5. I-refresh ang command list/detail para makita ang result. Read-only ang saved commands. Para mag-issue ulit, gumawa ng bagong command matapos tingnan ang PC.

Ang cloud user permissions ay sariling permissions ng cloud installation. Remote control dito ay para lamang sa staff admins/superusers; hindi awtomatikong binibigyan ng cross-campus permissions ang in-charge accounts.

## Mga resulta at safeguards

- `pending`: naghihintay sa edge.
- `accepted`: tinanggap ng agent ang signal. **Hindi pa ito confirmation na physically locked/off na ang PC.**
- `failed`: hindi pumasa sa local checks, halimbawa walang PC/IP o valid session para sa unlock.
- `expired`: lumampas sa expiry bago ma-execute.
- `unknown`: posibleng naipadala ang signal ngunit hindi tiyak ang resulta, o na-interrupt ang worker. Tingnan muna ang PC bago gumawa ng bagong command.

Hindi nirereplay nang automatic ang command pagkatapos maitala ang local receipt. Ang existing agent command API ay walang command-id deduplication, kaya hindi maaaring sabay garantiyahan ang retry at exactly-once physical execution. Kapag may crash/timeout, pinipiling mag-report ng uncertainty kaysa magpadala ulit ng restart/shutdown. Stale executing receipts become unknown after two minutes when the worker runs again.

Ang unlock ay para lamang sa kasalukuyang local session na tama ang lab, date, oras at may assigned user/guest, at hindi offline/maintenance/issue ang PC. Hindi ito remote reservation check-in o unrestricted manual unlock.

Kapag down ang internet/cloud, tuloy ang local system. Ang pending commands na lumampas sa expiry ay hindi tatakbo kapag bumalik ang connection. Nasa cloud command record ang requester, target, timestamps, at result; nasa edge receipt/log ang execution outcome. Huwag burahin ang edge receipts kung kailangang mapanatili ang replay protection.

## Verification

Kasama ang `cloud_receiver/test_remote_control.py`. All agent HTTP actions are mocked: no real PC was locked, restarted, or shut down during tests. Covered: TLS/authentication, site isolation, admin authorization/CSRF and submission, expiry, duplicate delivery, valid/invalid unlock session, outage recovery, crash uncertainty, redirect refusal, and cloud-edge round trip.

Run with the project's configured test database/environment:

```powershell
python manage.py test cloud_receiver.test_remote_control cloud_receiver.tests system.tests labs.test_agent_auth
```

Verification used isolated SQLite test databases, Python 3.12 and Django 5.0.14; 68 tests passed with no silenced system checks. Agent calls in the regression suite were mocked. Live HTTP connections were blocked by this coding environment, so actual network/PC operation still needs verification on your machine. Start with the simulated demo in `docs/LOCAL_REMOTE_DEMO.md`.

Walang desktop screen-sharing o mouse/keyboard streaming sa feature na ito.

