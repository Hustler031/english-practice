import MathsApp from "@/components/maths-app";

export default async function MathsRoute({params}:{params:Promise<{slug?:string[]}>}){
  const {slug=[]}=await params;
  return <MathsApp slug={slug}/>;
}
