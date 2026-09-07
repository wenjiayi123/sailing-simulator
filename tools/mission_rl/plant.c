/* Numerical accelerator only. No policy or guidance is implemented here.
 * Same RK4 plant and 60 Hz position integration as the simulator. */
#include <math.h>
static double clip(double x,double a,double b){return fmin(fmax(x,a),b);}
static double sign(double x){return (x>0)-(x<0);}
static void deriv(const double *s,const double *p,double port,double star,double angle,
                  double fx,double fy,double mz,double *d){
 double tp=.5*p[12]*port*(port>=0?1:p[13]);
 double ts=.5*p[12]*star*(star>=0?1:p[13]);
 double lateral=-(tp+ts)*sin(angle)*p[21];
 double mx=p[0]+p[2],my=p[0]+p[3],iz=p[1]+p[4];
 d[0]=((tp+ts)*cos(angle)-p[5]*s[0]-p[6]*fabs(s[0])*s[0]+fx+my*s[1]*s[2])/mx;
 d[1]=(lateral-p[7]*s[1]-p[8]*fabs(s[1])*s[1]+fy-mx*s[0]*s[2])/my;
 d[2]=((tp-ts)*p[16]+p[22]*lateral-p[9]*s[2]-p[10]*fabs(s[2])*s[2]+mz)/iz;
 d[3]=s[2];
}
/* state: x,z,surge,sway,yaw,heading,port,star,steering,time.
 * forcing: current x,z,wind magnitude,direction,wave magnitude,direction,period,
 * yaw arm,water depth,draft,shallow drag,bank half width,beam,bank range,force,moment,center.
 * samples store every physics frame, enabling swept collision checking. */
void advance(double *state,const double *p,const double *f,double throttle,double rudder,
             int frames,double *samples){
 double pt=clip(throttle+p[17]*rudder,-1,1),st=clip(throttle-p[17]*rudder,-1,1);
 double at=p[18]*rudder,dt=1./60.,h=dt/p[11];
 for(int frame=0;frame<frames;frame++){
  double hd=state[5],wv=f[4]*(.65+.35*sin(state[9]*2*M_PI/f[6]));
  double fx=f[2]*cos(f[3]-hd)+wv*cos(f[5]-hd);
  double fy=f[2]*sin(f[3]-hd)+wv*sin(f[5]-hd),mz=fy*f[7];
  double fr=clip(fabs(state[2])/sqrt(9.80665*fmax(f[8],.1)),0,.85);
  fx-=sign(state[2])*f[10]*state[2]*state[2]*(1+4*fr*fr);
  if(f[11]>0){
   double clearance=f[11]-fabs(state[0]-f[16])-f[12]*.5;
   double prox=clip((f[13]-fmax(clearance,0))/fmax(f[13],.1),0,1);
   double speed=clip(fabs(state[2])/5,0,1.5);
   double force=sign(state[0]-f[16])*f[14]*prox*speed;
   fx+=force*sin(hd);fy+=force*cos(hd);mz-=sign(force*cos(hd))*f[15]*prox*speed;
  }
  for(int i=0;i<(int)p[11];i++){
   state[6]+=clip((pt-state[6])/p[14],-p[15],p[15])*h;
   state[7]+=clip((st-state[7])/p[14],-p[15],p[15])*h;
   state[8]+=clip((at-state[8])/p[19],-p[20],p[20])*h;
   double y[4],k1[4],k2[4],k3[4],k4[4],tmp[4];
   for(int j=0;j<4;j++)y[j]=state[j+2];
   deriv(y,p,state[6],state[7],state[8],fx,fy,mz,k1);
   for(int j=0;j<4;j++)tmp[j]=y[j]+k1[j]*h*.5;
   deriv(tmp,p,state[6],state[7],state[8],fx,fy,mz,k2);
   for(int j=0;j<4;j++)tmp[j]=y[j]+k2[j]*h*.5;
   deriv(tmp,p,state[6],state[7],state[8],fx,fy,mz,k3);
   for(int j=0;j<4;j++)tmp[j]=y[j]+k3[j]*h;
   deriv(tmp,p,state[6],state[7],state[8],fx,fy,mz,k4);
   for(int j=0;j<4;j++)state[j+2]=y[j]+h*(k1[j]+2*k2[j]+2*k3[j]+k4[j])/6;
   state[5]=atan2(sin(state[5]),cos(state[5]));state[9]+=h;
  }
  state[0]+=(sin(state[5])*state[2]+cos(state[5])*state[3]+f[0])*dt;
  state[1]+=(cos(state[5])*state[2]-sin(state[5])*state[3]+f[1])*dt;
  samples[frame*2]=state[0];samples[frame*2+1]=state[1];
 }
}
