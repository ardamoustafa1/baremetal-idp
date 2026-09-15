import importlib.util
import unittest
from pathlib import Path
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('check-live.py'))
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
class Coverage(unittest.TestCase):
    def test_annotation_alone_does_not_prove_backup(self):
        pvc={'metadata':{'name':'data','namespace':'app'},'status':{'phase':'Bound'}}
        self.assertEqual(gate.uncovered_pvcs([pvc],[],[],[]),['app/data'])
    def test_completed_volume_backup_covers_actual_pvc(self):
        pvc={'metadata':{'name':'data','namespace':'app'},'status':{'phase':'Bound'}}
        pod={'metadata':{'uid':'id','namespace':'app'},'spec':{'volumes':[{'name':'disk','persistentVolumeClaim':{'claimName':'data'}}]}}
        backup={'spec':{'pod':{'uid':'id'},'volume':'disk'},'status':{'phase':'Completed','completionTimestamp':datetime.now(timezone.utc).isoformat()}}
        self.assertEqual(gate.uncovered_pvcs([pvc],[pod],[backup],[]),[])
        backup['status']['phase']='Failed'
        self.assertEqual(gate.uncovered_pvcs([pvc],[pod],[backup],[]),['app/data'])
    def test_old_and_future_timestamps_are_not_fresh(self):
        for stamp in ['2020-01-01T00:00:00Z','2999-01-01T00:00:00Z',None,'bad']:
            self.assertFalse(gate.recent(stamp))
if __name__=='__main__': unittest.main()
