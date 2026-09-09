import manifest from "@/data/grammar-curriculum-manifest.json";
import GrammarChapterClient from "./grammar-chapter-client";

export function generateStaticParams(){
 return Object.keys(manifest.chapters||{}).map(chapter=>({chapter}));
}

export default function GrammarChapterPage(){
 return <GrammarChapterClient/>;
}
