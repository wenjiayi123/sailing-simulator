"""Physical and mission acceptance tests for the independent direct-action RL branch."""
import json
import math
from pathlib import Path
import sys
import unittest
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from mission_rl.plant import Plant,forcing,DYNAMICS_PATH
from mission_rl.environment import MissionEnv,SCENARIOS,OBS_SIZE
from cargo_rl.catamaran_physics import TwinWaterjetCatamaran

class MissionRLTests(unittest.TestCase):
    def test_accelerated_rk4_matches_frozen_python_plant(self):
        p=Plant();q=TwinWaterjetCatamaran.from_json(DYNAMICS_PATH)
        sea={'wind_speed_knots':8,'wind_direction_degrees':40,'wave_height_meters':.3,
             'wave_direction_degrees':60,'wave_period_seconds':6,'current_speed_knots':.4,'current_direction_degrees':120}
        f=forcing({},sea);p.reset(2,-3,.7);q.reset(.7)
        position=np.array([2.,-3.])
        for i in range(600):
            a=[.4 if i<300 else -.2, .2*math.sin(i/80)]
            hd=q.heading_rad;wv=f[4]*(.65+.35*math.sin(q.simulation_time_s*2*math.pi/f[6]))
            fx=f[2]*math.cos(f[3]-hd)+wv*math.cos(f[5]-hd)
            fy=f[2]*math.sin(f[3]-hd)+wv*math.sin(f[5]-hd)
            v=q.step(*a,1/60,{'wind_force_body_x_n':fx,'wind_force_body_y_n':fy,
                'environment_yaw_moment_nm':fy*f[7],'current_east_mps':f[0],'current_north_mps':f[1]})
            position+=v['ground_velocity']/60;p.advance(a,f,1)
        np.testing.assert_allclose(p.state[:2],position,atol=1e-10,rtol=0)
        np.testing.assert_allclose(p.state[2:6],[q.surge_mps,q.sway_mps,q.yaw_rate_radps,q.heading_rad],atol=1e-10,rtol=0)

    def test_full_evaluation_never_uses_curriculum_resets(self):
        for key in SCENARIOS:
            env=MissionEnv(key,'validation')
            obs,_=env.reset(seed=10001)
            self.assertFalse(env.curriculum);self.assertEqual(env.waypoint,0)
            self.assertEqual(obs.shape,(OBS_SIZE,));self.assertTrue(env.observation_space.contains(obs))
            self.assertEqual(len(env.traffic),len(env.scenario.get('traffic',[])))
            self.assertEqual(len(env.boxes),len(env.scenario.get('boxes',[])))

    def test_docking_does_not_end_at_fast_waypoint_arrival(self):
        e=MissionEnv('auto_berthing','validation');e.reset(seed=0,options={'nominal':True})
        e.waypoint=len(e.route)-1;e.route_complete=True
        e.plant.reset(82,18,0,3)
        self.assertFalse(e.gate()['speed']);self.assertFalse(all(e.gate().values()))
        e.plant.reset(82,18,math.radians(30),0)
        self.assertFalse(e.gate()['heading'])
        e.plant.reset(82,18,0,0);e.plant.state[3]=.4
        self.assertFalse(e.gate()['sway'])

    def test_traffic_metrics_do_not_disappear_behind_nearest_bank(self):
        e=MissionEnv('narrow_channel_head_on','validation')
        e.plant.reset(-40,20,math.pi)
        e.traffic[0].reset(22,-30,0,2)
        self.assertLess(e.clearances(e.plant.state[None,:2])[0],np.linalg.norm(e.plant.state[:2]-e.traffic[0].state[:2]))
        self.assertEqual(e.observation()[25],1)
        self.assertEqual(len(e._dynamic()),1)

    def test_receding_contact_is_not_immediate_predicted_collision(self):
        e=MissionEnv('narrow_channel_head_on','validation');e.plant.reset(-22,-100,math.pi,3)
        e.traffic[0].reset(22,100,0,3)
        self.assertEqual(e._dynamic()[0][3],180.)

    def test_swept_collision_sees_thin_obstacle_between_endpoints(self):
        e=MissionEnv('open_water','validation')
        e.boxes=np.array([[0,0,.1,10]])
        e.rocks=np.zeros((0,3))
        endpoints=np.array([[-5.,0],[5.,0]])
        self.assertGreater(e.clearances(endpoints).min(),0)
        swept=np.linspace(endpoints[0],endpoints[1],30)
        self.assertLess(e.clearances(swept).min(),0)

    def test_overtaking_requires_agreement_and_actual_passing(self):
        e=MissionEnv('narrow_channel_overtaking','validation');e.reset(options={'overtaking_agreement':False})
        e.route_complete=True
        self.assertFalse(e.gate()['agreement']);self.assertFalse(e.gate()['passed_ahead'])

if __name__=='__main__':unittest.main()
