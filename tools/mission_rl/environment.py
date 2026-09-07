"""Direct neural throttle/rudder tasks with physical terminal business gates.

All geometry is read from the existing scene profile. Curriculum changes reset
states only; full held-out evaluation always begins at the configured spawn.
No controller, demonstration, action projection or expert fallback is used.
"""
import copy
import json
import math
from pathlib import Path
import gymnasium as gym
from gymnasium import spaces
import numpy as np
from .plant import Plant, forcing, ROOT

PROFILE_PATH=ROOT/'data/ports/default_port_profile.json'
SCENARIOS=('open_water','harbor','auto_berthing','auto_unberthing','narrow_channel_head_on','crossing_starboard','narrow_channel_overtaking')
OBS_SIZE=40
CONTRACT='mission_direct_sac_40d_v1'
CONFIG={'decision_frames':30,'max_steps':1200,'vessel_radius_m':3.2,'curriculum_probability':.7,
        'train_start_jitter_m':2.,'eval_start_jitter_m':1.,'heading_jitter_deg':4.,
        'environment_variation':.1,'success_hold_seconds':3.,'progress_weight':1.,
        'collision_penalty':150.,'success_bonus':120.,'step_cost':.15,
        'action_low':[-.6,-.65],'action_high':[.65,.65]}

def wrap(a): return (a+math.pi)%(2*math.pi)-math.pi

def local(dx,dz,h): return dx*math.sin(h)+dz*math.cos(h),dx*math.cos(h)-dz*math.sin(h)

class MissionEnv(gym.Env):
    metadata={'render_modes':[]}
    def __init__(self,scenario_key,split='train',seed=0,config=None,record=False):
        super().__init__()
        self.key=scenario_key; self.split=split; self.rng=np.random.default_rng(seed)
        self.config={**CONFIG,**(config or {})}; self.record=record
        profile=json.loads(PROFILE_PATH.read_text())
        self.scenario=copy.deepcopy(profile['scenarios'][scenario_key])
        self.mission=next(m for m in profile['navigation_missions'] if m['scenario_key']==scenario_key)
        self.route=np.array([[p['x'],p['z']] for p in self.scenario['route']],dtype=float)
        self.evaluation=self.scenario.get('evaluation',{})
        self.arrival=float(self.mission['arrival_radius'])
        self.dt=self.config['decision_frames']/60
        self.plant=Plant()
        self.action_space=spaces.Box(-1.,1.,shape=(2,),dtype=np.float32)
        self.observation_space=spaces.Box(-1.,1.,shape=(OBS_SIZE,),dtype=np.float32)
        self.boxes=np.array([[b['position']['x'],b['position']['z'],b['size']['x']/2,b['size']['z']/2] for b in self.scenario.get('boxes',[])],dtype=float).reshape(-1,4)
        self.rocks=np.array([[r['x'],r['z'],r.get('radius',6.)] for r in self.scenario.get('rocks',[])],dtype=float).reshape(-1,3)
        self.traffic=[]; self.traffic_actions=[]
        for t in self.scenario.get('traffic',[]):
            self.traffic.append(Plant());self.traffic_actions.append([t['throttle'],t.get('rudder',0)])
        self.curriculum_probability=self.config['curriculum_probability'] if split=='train' else 0
        self.reset(seed=seed)

    def reset(self,*,seed=None,options=None):
        super().reset(seed=seed)
        if seed is not None:self.rng=np.random.default_rng(seed)
        options=options or {}; nominal=bool(options.get('nominal',False))
        s=self.scenario['spawn']; x,z,h=s['x'],s['z'],math.radians(s['heading_degrees'])
        self.waypoint=0;self.curriculum=False
        if self.split=='train' and self.rng.random()<self.curriculum_probability:
            self.waypoint=int(self.rng.integers(len(self.route)))
            origin=np.array([x,z]) if self.waypoint==0 else self.route[self.waypoint-1]
            dest=self.route[self.waypoint]
            fraction=float(self.rng.uniform(0,.65))
            x,z=origin+(dest-origin)*fraction
            h=math.atan2(dest[0]-x,dest[1]-z)
            self.curriculum=True
        self.initial_waypoint=self.waypoint
        jitter=0 if nominal else self.config['train_start_jitter_m' if self.split=='train' else 'eval_start_jitter_m']
        x+=self.rng.uniform(-jitter,jitter);z+=self.rng.uniform(-jitter,jitter)
        h+=math.radians(self.rng.uniform(-self.config['heading_jitter_deg'],self.config['heading_jitter_deg'])) if not nominal else 0
        self.plant.reset(x,z,h)
        self.initial_position=np.array([s['x'],s['z']]);self.initial_heading=math.radians(s['heading_degrees'])
        self.sea=copy.deepcopy(self.scenario.get('realism',{}).get('environment',{}))
        # Same geometries and all configured traffic remain at every level.
        if not nominal:
            for key in ['wind_speed_knots','wave_height_meters','current_speed_knots']:
                self.sea[key]=self.sea.get(key,0)*self.rng.uniform(1-self.config['environment_variation'],1+self.config['environment_variation'])
        self.forcing=forcing(self.scenario,self.sea)
        self.traffic_forcing=self.forcing.copy();self.traffic_forcing[11]=0 # runtime excludes bank force for targets
        for plant,definition in zip(self.traffic,self.scenario.get('traffic',[])):
            spawn=definition['spawn'];plant.reset(spawn['x'],spawn['z'],math.radians(spawn['heading_degrees']))
        self.steps=0;self.reward_sum=0.;self.path_length=0.;self.effort=0.;self.action_variation=0.
        self.previous_action=np.zeros(2);self.collisions=0;self.hold_seconds=0.
        self.minimum_clearance=float(self.clearances(self.plant.state[None,:2]).min())
        self.minimum_separation=float('inf');self.closest_relation=None;self.passed_ahead=False
        self.first_action=None;self.lane_samples=0;self.lane_compliant=0;self.max_xte=0.
        self.minimum_ukc=float('inf');self.minimum_bank=float('inf');self.trajectory=[]
        self.route_complete=False; self.agreement=bool(options.get('overtaking_agreement',True))
        self.initial_distance=self.distance()
        self._update_encounter()
        if self.record:self._record(np.zeros(2))
        return self.observation(),{}

    def distance(self):return float(np.linalg.norm(self.route[self.waypoint]-self.plant.state[:2]))

    def clearances(self,positions):
        radius=self.config['vessel_radius_m']
        result=float(self.scenario['boundary_half_extent'])-np.max(np.abs(positions),axis=1)-radius
        for b in self.boxes:
            q=np.abs(positions-b[:2])-b[2:]
            d=np.linalg.norm(np.maximum(q,0),axis=1)+np.minimum(np.max(q,axis=1),0)-radius
            result=np.minimum(result,d)
        for r in self.rocks:result=np.minimum(result,np.linalg.norm(positions-r[:2],axis=1)-r[2]-radius)
        return result

    def _dynamic(self):
        s=self.plant.state;items=[]
        ownv=np.array([math.sin(s[5])*s[2]+math.cos(s[5])*s[3]+self.forcing[0],math.cos(s[5])*s[2]-math.sin(s[5])*s[3]+self.forcing[1]])
        for p in self.traffic:
            t=p.state;relative=t[:2]-s[:2]
            tv=np.array([math.sin(t[5])*t[2]+math.cos(t[5])*t[3]+self.forcing[0],math.cos(t[5])*t[2]-math.sin(t[5])*t[3]+self.forcing[1]])
            rv=tv-ownv;raw=-float(np.dot(relative,rv))/max(float(np.dot(rv,rv)),1e-9)
            tcpa=min(raw,180.) if raw>0 else 180.
            items.append((float(np.linalg.norm(relative)),relative,rv,tcpa,float(np.linalg.norm(relative+rv*tcpa)),t))
        return sorted(items,key=lambda x:x[0])

    def _update_encounter(self):
        s=self.plant.state
        for dist,relative,rv,tcpa,dcpa,t in self._dynamic():
            along=float(np.dot(s[:2]-t[:2],[math.sin(t[5]),math.cos(t[5])]))
            if dist<self.minimum_separation:
                self.minimum_separation=dist;self.closest_relation='ASTERN' if along<0 else 'AHEAD'
            if along>5.7:self.passed_ahead=True
            change=math.degrees(wrap(s[5]-self.initial_heading))
            if self.first_action is None and abs(change)>=10:
                self.first_action={'time':self.steps*self.dt,'distance':dist,'tcpa':tcpa,'side':'STARBOARD' if change>0 else 'PORT'}
        self.lane_samples+=1;self.lane_compliant+=int(s[0]<=0)

    def observation(self):
        s=self.plant.state;dx,dz=self.route[self.waypoint]-s[:2];dist=math.hypot(dx,dz)
        fwd,right=local(dx,dz,s[5]);bearing=wrap(math.atan2(dx,dz)-s[5])
        last=self.waypoint==len(self.route)-1
        dest_heading=math.radians(self.evaluation.get('berth_target',{}).get('heading_degrees',0))
        hd=wrap(dest_heading-s[5])
        nxt=self.route[min(self.waypoint+1,len(self.route)-1)]-self.route[self.waypoint]
        nb=wrap(math.atan2(nxt[0],nxt[1])-s[5]) if np.linalg.norm(nxt)>0 else 0
        obs=[dist/100,math.sin(bearing),math.cos(bearing),fwd/50,right/50,
             s[2]/11,s[3]/3,s[4]/.5,s[6],s[7],s[8]/math.radians(18),
             math.sin(nb),math.cos(nb),self.waypoint/max(len(self.route)-1,1),
             float(last),float(self.key=='auto_berthing'),math.sin(hd) if self.key=='auto_berthing' else 0,
             math.cos(hd) if self.key=='auto_berthing' else 0,
             *local(self.forcing[0],self.forcing[1],s[5]),
             float(self.clearances(s[None,:2])[0])/30,
             s[0]/self.scenario['boundary_half_extent'],s[1]/self.scenario['boundary_half_extent'],
             math.sin(s[5]),math.cos(s[5])]
        dyn=self._dynamic()
        if dyn:
            d,rel,vel,t,c,_=dyn[0];a,b=local(*rel,s[5]);u,v=local(*vel,s[5])
            obs.extend([1,a/200,b/100,u/11,v/11,t/180,c/100])
        else:obs.extend([0,0,0,0,0,1,1])
        obs.extend([float(self.first_action is not None),float(self.agreement),float(self.passed_ahead),
                    self.hold_seconds/self.config['success_hold_seconds'],
                    float(self.key=='narrow_channel_head_on'),float(self.key=='crossing_starboard'),
                    float(self.key=='narrow_channel_overtaking'),float(self.key=='auto_unberthing')])
        return np.clip(np.asarray(obs,dtype=np.float32),-1,1)

    def _physical_safety(self,positions):
        h=self.scenario.get('realism',{}).get('hydrodynamics',{});v=self.scenario.get('realism',{}).get('vessel',{})
        speed=abs(self.plant.state[2]);depth=self.forcing[8];draft=v.get('draft_m',0)
        fr=min(speed/math.sqrt(9.80665*depth),.85)**2
        squat=min(h.get('squat_coefficient',0)*draft*fr/max(1-fr,.15),draft*.65) if h.get('shallow_water_enabled') else 0
        self.minimum_ukc=min(self.minimum_ukc,depth-draft-squat)
        if h.get('bank_effect_enabled'):
            bank=h['navigable_half_width_m']-np.abs(positions[:,0]-h.get('channel_center_x_m',0))-v.get('beam_m',2.95)*.5
            self.minimum_bank=min(self.minimum_bank,float(bank.min()))

    def gate(self):
        s=self.plant.state;e=self.evaluation;key=self.key
        checks={'all_waypoints':self.route_complete,'collision_free':self.collisions==0,'positive_clearance':self.minimum_clearance>0}
        h=self.scenario.get('realism',{}).get('hydrodynamics',{})
        checks['under_keel_clearance']=self.minimum_ukc>=h.get('minimum_ukc_m',0)
        checks['bank_clearance']=self.minimum_bank>=h.get('minimum_bank_clearance_m',0)
        if key=='auto_berthing':
            target=e['berth_target'];dist=np.linalg.norm(s[:2]-[target['x'],target['z']])
            checks.update(position=dist<=e['position_tolerance_m'],heading=abs(math.degrees(wrap(math.radians(target['heading_degrees'])-s[5])))<=e['heading_tolerance_degrees'],
                          speed=abs(s[2])/.514444<=e['maximum_speed_knots'],sway=abs(s[3])<=e['maximum_sway_mps'])
        if key=='auto_unberthing':
            checks.update(clear_distance=np.linalg.norm(s[:2]-self.initial_position)>=e['minimum_clear_distance_m'],exit_speed=abs(s[2])/.514444<=e['maximum_exit_speed_knots'])
        if self.traffic:
            checks['separation']=self.minimum_separation>=e['minimum_passing_distance_m']
            if key in ('narrow_channel_head_on','crossing_starboard'):
                a=self.first_action or {};checks['early_starboard_action']=a.get('side')=='STARBOARD' and a.get('distance',0)>=60 and a.get('tcpa',0)>=20
            if key=='narrow_channel_head_on':checks['starboard_lane']=self.lane_compliant/max(self.lane_samples,1)>=.9
            if key=='crossing_starboard':checks['astern_passing']=self.closest_relation=='ASTERN'
            if key=='narrow_channel_overtaking':checks.update(agreement=self.agreement,passed_ahead=self.passed_ahead)
        return {k:bool(v) for k,v in checks.items()}

    def step(self,action):
        raw=np.clip(np.asarray(action,dtype=float),-1,1)
        low=np.array(self.config['action_low']);high=np.array(self.config['action_high'])
        command=low+(raw+1)*.5*(high-low)
        old=self.plant.state[:2].copy();old_dist=self.distance();previous_first=self.first_action
        samples=self.plant.advance(command,self.forcing,self.config['decision_frames'])
        clearance=float(self.clearances(samples).min())
        for p,a in zip(self.traffic,self.traffic_actions):
            target_samples=p.advance(a,self.traffic_forcing,self.config['decision_frames'])
            distances=np.linalg.norm(samples-target_samples,axis=1)
            clearance=min(clearance,float(distances.min())-self.config['vessel_radius_m']*2)
        self.steps+=1;self.minimum_clearance=min(self.minimum_clearance,clearance)
        self._physical_safety(samples);self._update_encounter()
        collided=clearance<=0;self.collisions+=int(collided)
        dist=self.distance();s=self.plant.state;last=self.waypoint==len(self.route)-1
        dock=last and self.key=='auto_berthing'
        reward=(old_dist-dist)*self.config['progress_weight']-self.config['step_cost']
        target_speed=3.5
        if self.key=='auto_unberthing':target_speed=2.
        if self.key=='narrow_channel_overtaking':target_speed=5.8
        if dock:target_speed=min(2.,dist*.15)
        reward-=.08*(s[2]-target_speed)**2+.04*abs(raw[1]-self.previous_action[1])+.015*abs(raw[1])
        if clearance<8:reward-=.3*(8-clearance)
        if dock:
            target=self.evaluation['berth_target'];herr=abs(wrap(math.radians(target['heading_degrees'])-s[5]))
            reward-=max(0,1-dist/30)*(.8*herr+.15*abs(s[3]))
        if self.key in ('narrow_channel_head_on','crossing_starboard') and self.first_action is None:
            change=wrap(s[5]-self.initial_heading)
            reward+=.3*min(change/math.radians(12),1)
        if previous_first is None and self.first_action is not None:
            reward+=4 if self.first_action['side']=='STARBOARD' else -8
        if self.key=='narrow_channel_head_on' and s[0]>0:reward-=2
        if self.traffic:
            d,*_=self._dynamic()[0];safe=self.evaluation['minimum_passing_distance_m']
            if d<safe+10:reward-=2*max(0,(safe+10-d)/10)
        if dist<=self.arrival and not last:
            self.waypoint+=1;reward+=8
        elif dist<=self.arrival and last:self.route_complete=True
        gate=self.gate()
        if all(gate.values()):self.hold_seconds+=self.dt
        else:self.hold_seconds=0
        success=all(gate.values()) and (not dock or self.hold_seconds>=self.config['success_hold_seconds'])
        if success:reward+=self.config['success_bonus']
        if collided:reward-=self.config['collision_penalty']
        terminated=success or collided
        truncated=self.steps>=self.config['max_steps'] and not terminated
        self.path_length+=float(np.linalg.norm(s[:2]-old));self.effort+=float(np.sum(np.abs(command)))*self.dt
        self.action_variation+=float(np.sum(np.abs(raw-self.previous_action)))
        self.previous_action=raw;self.reward_sum+=reward
        if self.record:self._record(command)
        info={}
        if terminated or truncated:
            info=self.result(success);info['episode']={'r':self.reward_sum,'l':self.steps}
        return self.observation(),float(reward),terminated,truncated,info

    def _record(self,action):
        s=self.plant.state
        self.trajectory.append({'time':self.steps*self.dt,'x':float(s[0]),'z':float(s[1]),'heading_degrees':math.degrees(s[5])%360,
          'speed':float(s[2]),'sway_mps':float(s[3]),'yaw_rate_radps':float(s[4]),'throttle_command':float(action[0]),'rudder_command':float(action[1]),
          'waypoint_index':self.waypoint,'dynamic_obstacles':[{'x':float(p.state[0]),'z':float(p.state[1]),'heading_degrees':math.degrees(p.state[5])%360} for p in self.traffic]})

    def result(self,success=False):
        s=self.plant.state
        return {'scenario_key':self.key,'split':self.split,'success':bool(success),'gates':self.gate(),
          'reward':self.reward_sum,'steps':self.steps,'duration_seconds':self.steps*self.dt,'path_length_m':self.path_length,
          'actuator_effort_proxy':self.effort,'action_total_variation':self.action_variation,
          'collisions':self.collisions,'minimum_clearance_m':self.minimum_clearance,
          'minimum_separation_m':self.minimum_separation if self.traffic else None,
          'minimum_ukc_m':self.minimum_ukc,'minimum_bank_m':self.minimum_bank if self.minimum_bank!=float('inf') else None,
          'waypoints_completed':self.waypoint+int(self.route_complete),'total_waypoints':len(self.route),
          'final_distance_m':self.distance(),'final_speed_knots':abs(float(s[2]))/.514444,
          'final_sway_mps':float(s[3]),'final_heading_degrees':math.degrees(s[5])%360,
          'first_substantial_action':self.first_action,'curriculum_reset':self.curriculum,
          'action_source':'neural_policy_direct','controller_fallback_steps':0,'production_authority':False}
