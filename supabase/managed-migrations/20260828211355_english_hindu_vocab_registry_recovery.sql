-- Historical mirror with one deliberate portability/security change:
-- the live migration used a concrete auth.users UUID for the single owner.
-- This public-repository mirror resolves that owner at runtime and refuses to run unless exactly one auth user exists.

create table if not exists legacy.english_hindu_vocab_list_raw(
 source_row integer primary key,
 hindu_id text not null,
 question_id text,
 added_date date,
 marked boolean,
 in_vocab boolean,
 active boolean
);
truncate legacy.english_hindu_vocab_list_raw;
insert into legacy.english_hindu_vocab_list_raw(source_row,hindu_id,question_id,added_date,marked,in_vocab,active) values
(2,'HINDU20260815_03','HV20260815_003','2026-08-15',false,true,true),(3,'HINDU20260815_04','HV20260815_004','2026-08-15',false,true,true),(4,'HINDU20260815_05','HV20260815_005','2026-08-15',false,true,true),(5,'HINDU20260815_07','HV20260815_007','2026-08-15',false,true,true),(6,'HINDU20260815_09','HV20260815_009','2026-08-15',true,true,true),(7,'HINDU20260815_10','HV20260815_010','2026-08-15',false,true,true),(8,'HINDU20260815_02','HV20260815_002','2026-08-15',true,true,true),
(9,'HINDU20260816_02','HV20260816_002','2026-08-16',true,true,true),(10,'HINDU20260816_03','HV20260816_003','2026-08-16',false,true,true),(11,'HINDU20260816_06','HV20260816_006','2026-08-16',true,true,true),(12,'HINDU20260816_07','HV20260816_007','2026-08-16',false,true,true),(13,'HINDU20260816_08','HV20260816_008','2026-08-16',false,true,true),(14,'HINDU20260816_09','HV20260816_009','2026-08-16',false,true,true),(15,'HINDU20260816_10','HV20260816_010','2026-08-16',false,true,true),(16,'HINDU20260816_11','HV20260816_011','2026-08-16',false,true,true),(17,'HINDU20260816_14','HV20260816_014','2026-08-16',true,true,true),(18,'HINDU20260816_16','HV20260816_016','2026-08-16',true,true,true),(19,'HINDU20260816_17','HV20260816_017','2026-08-16',false,true,true),(20,'HINDU20260816_18','HV20260816_018','2026-08-16',true,true,true),
(21,'HINDU20260817_03','HV20260817_003','2026-08-17',true,true,true),(22,'HINDU20260817_01','HV20260817_001',null,true,false,true),(23,'HINDU20260817_08','HV20260817_008',null,true,false,true),(24,'HINDU20260817_10','HV20260817_010',null,true,false,true),(25,'HINDU20260817_11','HV20260817_011',null,true,false,true),(26,'HINDU20260817_15','HV20260817_015','2026-08-17',true,true,true),(27,'HINDU20260817_16','HV20260817_016','2026-08-17',true,true,true),(28,'HINDU20260817_18','HV20260817_018','2026-08-17',true,true,true),(29,'HINDU20260817_19','HV20260817_019','2026-08-17',true,true,true),(30,'HINDU20260817_20','HV20260817_020','2026-08-17',false,true,true),
(31,'HINDU20260818_01','HV20260818_001',null,true,false,true),(32,'HINDU20260818_04','HV20260818_004',null,true,false,true),(33,'HINDU20260818_08','HV20260818_008',null,true,false,true),(34,'HINDU20260818_07','HV20260818_007',null,true,false,true),(35,'HINDU20260818_13','HV20260818_013','2026-08-18',true,true,true),(36,'HINDU20260818_14','HV20260818_014','2026-08-18',true,true,true),(37,'HINDU20260818_11','HV20260818_011','2026-08-18',false,true,true),
(38,'HINDU20260819_01','HV20260819_001',null,true,false,true),(39,'HINDU20260819_03','HV20260819_003','2026-08-19',true,true,true),(40,'HINDU20260819_06','HV20260819_006',null,true,false,true),(41,'HINDU20260819_07','HV20260819_007','2026-08-19',true,true,true),(42,'HINDU20260819_09','HV20260819_009','2026-08-19',true,true,true),(43,'HINDU20260819_12','HV20260819_012','2026-08-20',true,true,true),(44,'HINDU20260819_13','HV20260819_013','2026-08-20',true,true,true),(45,'HINDU20260819_17','HV20260819_017',null,true,false,true),(46,'HINDU20260819_18','HV20260819_018','2026-08-20',false,true,true),(47,'HINDU20260819_19','HV20260819_019','2026-08-20',true,true,true),
(48,'HINDU20260820_02','HV20260820_002','2026-08-20',true,true,true),(49,'HINDU20260820_04','HV20260820_004',null,true,false,true),(50,'HINDU20260820_07','HV20260820_007','2026-08-20',true,true,true),(51,'HINDU20260820_09','HV20260820_009',null,true,false,true),(52,'HINDU20260820_12','HV20260820_012','2026-08-20',true,true,true),(53,'HINDU20260820_13','HV20260820_013',null,true,false,true),(54,'HINDU20260820_14','HV20260820_014','2026-08-20',true,true,true),(55,'HINDU20260820_15','HV20260820_015',null,true,false,true),(56,'HINDU20260820_17','HV20260820_017',null,true,false,true),(57,'HINDU20260820_18','HV20260820_018','2026-08-20',true,true,true),
(58,'HINDU20260821_02','HV20260821_002',null,true,false,true),(59,'HINDU20260821_06','HV20260821_006',null,true,false,true),
(60,'HINDU20260822_07','HV20260822_007',null,true,false,true),(61,'HINDU20260822_08','HV20260822_008',null,true,false,true),(62,'HINDU20260822_09','HV20260822_009',null,true,false,true),(63,'HINDU20260822_13','HV20260822_013',null,true,false,true),(64,'HINDU20260822_14','HV20260822_014',null,true,false,true),(65,'HINDU20260822_16','HV20260822_016',null,true,false,true),(66,'HINDU20260822_19','HV20260822_019',null,true,false,true),(67,'HINDU20260822_20','HV20260822_020',null,true,false,true),
(68,'HINDU20260823_04','HV20260823_004',null,true,false,true),(69,'HINDU20260823_06','HV20260823_006',null,true,false,true),(70,'HINDU20260823_11','HV20260823_011',null,true,false,true),(71,'HINDU20260823_13','HV20260823_013',null,true,false,true),(72,'HINDU20260823_14','HV20260823_014',null,true,false,true),(73,'HINDU20260823_15','HV20260823_015',null,true,false,true),(74,'HINDU20260823_19','HV20260823_019',null,true,false,true),(75,'HINDU20260823_01','HV20260823_001','2026-08-23',false,true,true),
(76,'HINDU20260824_02','HV20260824_002',null,true,false,true),(77,'HINDU20260824_03','HV20260824_003',null,true,false,true),(78,'HINDU20260824_04','HV20260824_004',null,true,false,true),(79,'HINDU20260824_05','HV20260824_005',null,true,false,true),(80,'HINDU20260824_08','HV20260824_008',null,true,false,true),(81,'HINDU20260824_16','HV20260824_016',null,true,false,true),(82,'HINDU20260824_19','HV20260824_019',null,true,false,true),
(83,'HINDU20260825_01','HV20260825_001',null,true,false,true),(84,'HINDU20260825_06','HV20260825_006',null,true,false,true),(85,'HINDU20260825_07','HV20260825_007',null,true,false,true),(86,'HINDU20260825_08','HV20260825_008',null,true,false,true),(87,'HINDU20260825_09','HV20260825_009',null,true,false,true),(88,'HINDU20260825_10','HV20260825_010',null,true,false,true),(89,'HINDU20260825_12','HV20260825_012',null,true,false,true),(90,'HINDU20260825_15','HV20260825_015',null,true,false,true),(91,'HINDU20260825_16','HV20260825_016',null,true,false,true),(92,'HINDU20260825_18','HV20260825_018',null,true,false,true),(93,'HINDU20260825_19','HV20260825_019',null,true,false,true),
(94,'HINDU20260827_03','HV20260827_003',null,true,false,true),(95,'HINDU20260827_06','HV20260827_006',null,true,false,true),(96,'HINDU20260827_07','HV20260827_007',null,true,false,true),(97,'HINDU20260827_08','HV20260827_008',null,true,false,true),(98,'HINDU20260827_10','HV20260827_010',null,true,false,true),(99,'HINDU20260827_11','HV20260827_011',null,true,false,true),(100,'HINDU20260827_13','HV20260827_013','2026-08-27',false,true,true),(101,'HINDU20260827_16','HV20260827_016',null,true,false,true),(102,'HINDU20260827_18','HV20260827_018',null,true,false,true),(103,'HINDU20260827_19','HV20260827_019',null,true,false,true),(104,'HINDU20260827_20','HV20260827_020',null,true,false,true),
(105,'HINDU20260828_01','HV20260828_001',null,true,false,true),(106,'HINDU20260828_04','HV20260828_004',null,true,false,true),(107,'HINDU20260828_05','HV20260828_005','2026-08-28',false,true,true),(108,'HINDU20260828_07','HV20260828_007','2026-08-28',false,true,true),(109,'HINDU20260828_15','HV20260828_015',null,true,false,true),(110,'HINDU20260828_16','HV20260828_016',null,true,false,true);

create table if not exists english.hindu_vocab_registry(
 user_id uuid not null references auth.users(id) on delete cascade,
 hindu_id text not null,
 question_id text references english.questions(question_id) on delete set null,
 added_date date,
 marked boolean not null default false,
 in_vocab boolean not null default false,
 active boolean not null default true,
 source_row integer,
 updated_at timestamptz not null default now(),
 primary key(user_id,hindu_id)
);
alter table english.hindu_vocab_registry enable row level security;
drop policy if exists english_hindu_vocab_registry_own on english.hindu_vocab_registry;
create policy english_hindu_vocab_registry_own on english.hindu_vocab_registry for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

do $$
declare owner_uid uuid; owner_count integer;
begin
 select count(*),min(id) into owner_count,owner_uid from auth.users;
 if owner_count<>1 then raise exception 'Expected exactly one auth user for historical Hindu registry recovery; found %',owner_count; end if;
 insert into english.hindu_vocab_registry(user_id,hindu_id,question_id,added_date,marked,in_vocab,active,source_row)
 select owner_uid,r.hindu_id,case when q.question_id is not null then r.question_id end,r.added_date,coalesce(r.marked,false),coalesce(r.in_vocab,false),coalesce(r.active,true),r.source_row
 from legacy.english_hindu_vocab_list_raw r left join english.questions q on q.question_id=r.question_id
 on conflict(user_id,hindu_id) do update set question_id=excluded.question_id,added_date=excluded.added_date,marked=excluded.marked,in_vocab=excluded.in_vocab,active=excluded.active,source_row=excluded.source_row,updated_at=now();
end $$;
