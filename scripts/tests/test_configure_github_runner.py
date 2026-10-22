import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'configure_runner', Path(__file__).resolve().parents[1] / 'configure-github-runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class DrainWorkersTest(unittest.TestCase):
    def setUp(self):
        self.config = {'runner_repository': 'owner/repo', 'runner_name': 'home-server-supa-crm',
                       'runner_count': 2}
        self.primary = {'id': 21, 'name': 'home-server-supa-crm', 'busy': True,
                        'labels': [{'name': 'home-server'}]}
        self.benchmark = {'id': 22, 'name': 'home-server-benchmark-01', 'busy': True,
                          'labels': [{'name': 'home-server-benchmark'}]}

    def test_stops_intake_then_waits_without_touching_benchmark_workers(self):
        reads = iter([
            {'runners': [self.primary, self.benchmark]},
            {'runners': [self.primary, self.benchmark]},
            {'runners': [dict(self.primary, busy=False), self.benchmark]},
        ])
        mutations = []

        def api(path, method='GET', data=None):
            if method == 'GET':
                return next(reads)
            mutations.append((path, method, data))

        with patch.object(runner, 'github', side_effect=api), patch.object(runner.time, 'sleep') as sleep:
            endpoint, removed = runner.drain_workers(self.config)
            sleep.assert_called_once_with(5)
            runner.restore_workers(endpoint, removed)
        self.assertEqual(removed, [21])
        self.assertEqual(mutations, [
            ('repos/owner/repo/actions/runners/21/labels/home-server', 'DELETE', None),
            ('repos/owner/repo/actions/runners/21/labels', 'POST', {'labels': ['home-server']}),
        ])

    def test_restores_intake_if_the_status_query_fails(self):
        calls = []
        reads = 0

        def api(path, method='GET', data=None):
            nonlocal reads
            if method == 'GET':
                reads += 1
                if reads == 1:
                    return {'runners': [self.primary]}
                raise RuntimeError('network failure')
            calls.append((method, data))

        with patch.object(runner, 'github', side_effect=api):
            with self.assertRaisesRegex(RuntimeError, 'network failure'):
                runner.drain_workers(self.config)
        self.assertEqual(calls, [('DELETE', None), ('POST', {'labels': ['home-server']})])

    def test_refuses_an_unretired_surplus_worker_before_changing_intake(self):
        extra = dict(self.primary, id=33, name='home-server-supa-crm-03')
        with patch.object(runner, 'github', return_value={'runners': [extra]}) as api:
            with self.assertRaisesRegex(RuntimeError, 'Retire surplus'):
                runner.drain_workers(self.config)
            api.assert_called_once()

    def test_timeout_restores_intake(self):
        changes = []

        def api(path, method='GET', data=None):
            if method == 'GET':
                return {'runners': [self.primary]}
            changes.append(method)

        with patch.object(runner, 'github', side_effect=api), \
                patch.object(runner.time, 'monotonic', side_effect=[0, 1801]):
            with self.assertRaisesRegex(RuntimeError, 'Timed out draining'):
                runner.drain_workers(self.config)
        self.assertEqual(changes, ['DELETE', 'POST'])


if __name__ == '__main__':
    unittest.main()
