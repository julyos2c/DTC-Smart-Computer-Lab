"""Per-PC agent secrets (labs/agent_auth.py): see who still uses the shared
secret, or replace one PC's secret.

    python manage.py agent_secret                 list every PC and which secret it uses
    python manage.py agent_secret --rotate 12     new secret for the PC with database id 12

After --rotate, the agent on that PC is no longer accepted: download its
Agent config again (PC power status > Agent config) and re-run the agent
setup on the PC. Secrets are never printed.
"""
from django.core.management.base import BaseCommand, CommandError

from labs import agent_auth
from labs.models import PC


class Command(BaseCommand):
    help = 'Lists which agent secret each lab PC uses, or rotates one PC\'s secret.'

    def add_arguments(self, parser):
        parser.add_argument('--rotate', type=int, metavar='PC_ID', help='Database id of the PC whose secret to replace.')

    def handle(self, *args, **options):
        if options['rotate']:
            pc = PC.objects.select_related('lab').filter(pk=options['rotate']).first()
            if pc is None:
                raise CommandError(f'No PC with id {options["rotate"]}.')
            agent_auth.rotate_secret(pc)
            self.stdout.write(f'{pc.pc_id} ({pc.lab.name}) has a new agent secret. Download its Agent config again '
                              'and re-run the agent setup on that PC; until then it is not accepted.')
            return
        pcs = list(PC.objects.select_related('lab').order_by('lab__name', 'pc_id'))
        for pc in pcs:
            state = ('own secret' if pc.agent_secret_in_use else
                     'own secret downloaded, agent not reinstalled yet' if pc.agent_secret else 'shared secret')
            self.stdout.write(f'{pc.pk:>5}  {pc.lab.name:<24} {pc.pc_id:<10} {state}')
        s = agent_auth.summary(pcs)
        self.stdout.write(f'{s["own"]} of {s["total"]} PCs use their own secret; shared secret '
                          f'{"still accepted" if s["shared_allowed"] else "switched off"}.')
