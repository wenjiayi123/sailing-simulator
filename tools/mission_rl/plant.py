"""Build a source-hashed numerical accelerator in the OS temporary directory."""
import ctypes
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
DYNAMICS_PATH = ROOT / 'data/verification/catamaran_usv_dynamics_reference_v2.json'
KEYS = ['mass_kg','yaw_inertia_kg_m2','added_mass_surge_kg','added_mass_sway_kg',
        'added_yaw_inertia_kg_m2','surge_drag_linear_n_per_mps','surge_drag_quadratic_n_per_mps2',
        'sway_drag_linear_n_per_mps','sway_drag_quadratic_n_per_mps2','yaw_drag_linear_nm_per_radps',
        'yaw_drag_quadratic_nm_per_radps2','integration_substeps','max_ahead_thrust_n','astern_thrust_ratio',
        'propeller_time_constant_s','max_throttle_rate_per_s','twin_waterjet_half_spacing_m',
        'differential_thrust_gain','max_steering_angle_deg','steering_time_constant_s',
        'max_steering_rate_deg_s','steering_lateral_efficiency','steering_x_m']
_LIB = None

def library():
    global _LIB
    if _LIB is None:
        src = Path(__file__).with_suffix('.c')
        digest = hashlib.sha256(src.read_bytes()).hexdigest()[:20]
        folder = Path(tempfile.gettempdir()) / 'sailing_mission_rl'
        folder.mkdir(exist_ok=True)
        binary = folder / (digest + ('.dylib' if sys.platform == 'darwin' else '.so'))
        if not binary.exists():
            with tempfile.NamedTemporaryFile(dir=folder, delete=False) as tmp:
                target = Path(tmp.name)
            try:
                subprocess.run(['cc', '-O3', '-shared', '-fPIC', str(src), '-o', str(target), '-lm'],check=True,capture_output=True)
                target.replace(binary)
            finally:
                target.unlink(missing_ok=True)
        _LIB = ctypes.CDLL(str(binary))
        arr = np.ctypeslib.ndpointer(dtype=np.float64,flags='C_CONTIGUOUS')
        _LIB.advance.argtypes = [arr,arr,arr,ctypes.c_double,ctypes.c_double,ctypes.c_int,arr]
        _LIB.advance.restype = None
    return _LIB

class Plant:
    def __init__(self, config=None):
        self.config = config or json.loads(DYNAMICS_PATH.read_text())
        self.parameters = np.array([self.config[k] for k in KEYS],dtype=np.float64)
        self.parameters[[18,20]] *= math.pi/180
        self.state = np.zeros(10,dtype=np.float64)
        self.lib = library()

    def reset(self,x,z,heading,speed=0):
        self.state[:] = 0
        self.state[[0,1,2,5]] = [x,z,speed,heading]

    def advance(self,action,forcing,frames=30):
        samples=np.empty((frames,2),dtype=np.float64)
        self.lib.advance(self.state,self.parameters,forcing,float(action[0]),float(action[1]),frames,samples)
        if not np.isfinite(self.state).all():
            raise FloatingPointError('non-finite mission plant')
        return samples

def forcing(scenario,sea):
    c=json.loads(DYNAMICS_PATH.read_text())
    r=scenario.get('realism',{})
    h=r.get('hydrodynamics',{}); v=r.get('vessel',{})
    cur=sea.get('current_speed_knots',0)*.514444
    direction=math.radians(sea.get('current_direction_degrees',0))
    wind=sea.get('wind_speed_knots',0)*.514444
    return np.array([cur*math.sin(direction),cur*math.cos(direction),
      .5*c['air_density_kg_m3']*c['wind_drag_coefficient']*c['wind_lateral_area_m2']*wind*wind,
      math.radians(sea.get('wind_direction_degrees',0)),
      c['wave_drift_force_n_per_meter']*sea.get('wave_height_meters',0),
      math.radians(sea.get('wave_direction_degrees',0)),max(sea.get('wave_period_seconds',6),1),
      c['environment_yaw_arm_m'],h.get('water_depth_m',100)+sea.get('tide_meters',0),
      v.get('draft_m',0),h.get('shallow_drag_n_per_mps2',0) if h.get('shallow_water_enabled') else 0,
      h.get('navigable_half_width_m',0) if h.get('bank_effect_enabled') else 0,
      v.get('beam_m',2.95),h.get('bank_influence_distance_m',1),h.get('bank_suction_force_n',0),
      h.get('bank_yaw_moment_nm',0),h.get('channel_center_x_m',0)],dtype=np.float64)
