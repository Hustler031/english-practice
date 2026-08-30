create or replace function maths._chapter_group(v text)
returns text
language sql
immutable
set search_path = pg_catalog, public, maths
as $$
  select case
    when maths._norm(v) in (
      'algebra','geometry','coordinate geometry','trigonometry','mensuration 2d','mensuration 3d'
    ) then 'advanced'
    when maths._norm(v) ~ '(fraction pattern|triplet|calculation memory|square|cube)' then 'misc'
    when maths._norm(v) ~ '(percentage|profit|loss|discount|(^|[^a-z])ratio([^a-z]|$)|proportion|average|mixture|alligation|interest|time.*work|pipe|cistern|speed|distance|train|boat|stream|partnership|ages|work.*wage)' then 'arithmetic'
    else 'advanced'
  end
$$;

revoke all on function maths._chapter_group(text) from public, anon, authenticated;
