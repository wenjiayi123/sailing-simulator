"""Fast numerical implementation of the existing P47 plant, without policy changes."""
import numpy as np
from mission_rl.plant import Plant,forcing
from .physics_environment import CargoPhysicsV4Env

class AcceleratedCargoPhysicsEnv(CargoPhysicsV4Env):
    def _integrate(self,throttle_command,rudder_command):
        if not hasattr(self,'_fast_plant'):
            self._fast_plant=Plant(self._physics_config)
        q=self._physics;p=self._fast_plant
        p.state[:]=[self.state[0],self.state[1],q.surge_mps,q.sway_mps,q.yaw_rate_radps,q.heading_rad,
                     q.port_throttle,q.starboard_throttle,q.steering_angle_rad,q.simulation_time_s]
        frames=round(self.delta*60)
        if frames<=0 or abs(frames/60-self.delta)>1e-10:
            return super()._integrate(throttle_command,rudder_command)
        p.advance([throttle_command,rudder_command],forcing({},self.sea_state),frames)
        self.state[:2]=p.state[:2]
        (q.surge_mps,q.sway_mps,q.yaw_rate_radps,q.heading_rad,q.port_throttle,q.starboard_throttle,
            q.steering_angle_rad,q.simulation_time_s)=map(float,p.state[2:])
        self._sync_from_physics(self._forcing())
