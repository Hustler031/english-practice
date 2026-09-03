import type { ReactNode } from "react";

export function PageHeader({back,eyebrow,title,subtitle}:{back?:ReactNode;eyebrow?:string;title:string;subtitle:string}) {
 return <section className="learner-page-header">{back}{eyebrow&&<span className="learner-eyebrow">{eyebrow}</span>}<h1>{title}</h1><p>{subtitle}</p></section>;
}

export function OverviewCard({tone="neutral",title,subtitle,count,onClick,children}:{tone?:"fix"|"soon"|"good"|"later"|"neutral";title:string;subtitle:string;count?:number|string;onClick?:()=>void;children?:ReactNode}) {
 const content=<><span className="learner-card-icon" aria-hidden>{tone==="fix"?"!":tone==="soon"?"↗":tone==="good"?"✓":tone==="later"?"◷":"•"}</span><span className="learner-card-copy"><b>{title}</b><small>{subtitle}</small></span>{count!==undefined&&<strong className="learner-card-count">{count}</strong>}</>;
 return onClick?<button type="button" className={`learner-overview-card tone-${tone}`} onClick={onClick}>{content}{children}</button>:<div className={`learner-overview-card tone-${tone}`}>{content}{children}</div>;
}

export function LearnerRow({title,subtitle,status,onClick,tone="neutral"}:{title:string;subtitle?:string;status?:string;onClick?:()=>void;tone?:"fix"|"soon"|"good"|"later"|"neutral"}) {
 const content=<><span className="learner-row-dot" aria-hidden/><span className="learner-row-copy"><b>{title}</b>{subtitle&&<small>{subtitle}</small>}{status&&<em>{status}</em>}</span></>;
 return onClick?<button className={`learner-row tone-${tone}`} type="button" onClick={onClick}>{content}</button>:<div className={`learner-row tone-${tone}`}>{content}</div>;
}
