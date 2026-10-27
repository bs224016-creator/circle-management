-- Run in Supabase SQL Editor after the 8 audition tables from the previous step exist.
BEGIN;
ALTER TABLE public.audition_scores ADD COLUMN IF NOT EXISTS comment text;
CREATE TABLE IF NOT EXISTS public.audition_entry_members (
 entry_id uuid NOT NULL REFERENCES public.audition_entries(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES public.profiles(id),
 PRIMARY KEY(entry_id,user_id)
);
ALTER TABLE public.audition_entry_members ENABLE ROW LEVEL SECURITY;

-- No direct client access to sensitive tables. All writes/readback use validated RPCs.
REVOKE ALL ON public.audition_scores, public.audition_results, public.audition_entry_members FROM anon, authenticated;
REVOKE ALL ON public.audition_penalties FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.audition_create(
 p_title text, p_description text, p_entry_deadline timestamptz,
 p_scoring_deadline timestamptz, p_general_slots integer,
 p_freshman_slots integer, p_criteria jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_c jsonb; v_count integer := 0;
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ作成できます'; END IF;
 IF nullif(trim(p_title),'') IS NULL OR length(p_title)>100 THEN RAISE EXCEPTION 'タイトルが不正です'; END IF;
 IF p_entry_deadline IS NULL OR p_scoring_deadline <= p_entry_deadline OR p_scoring_deadline IS NULL THEN RAISE EXCEPTION '締切が不正です'; END IF;
 IF p_general_slots < 0 OR p_freshman_slots < 0 OR p_general_slots IS NULL OR p_freshman_slots IS NULL THEN RAISE EXCEPTION '枠数が不正です'; END IF;
 IF jsonb_typeof(p_criteria) IS DISTINCT FROM 'array' OR jsonb_array_length(p_criteria) = 0 OR jsonb_array_length(p_criteria)>20 THEN RAISE EXCEPTION '採点項目は1〜20件です'; END IF;
 INSERT INTO public.auditions(title,description,created_by,status,entry_deadline,scoring_deadline,general_slots,freshman_slots)
 VALUES(trim(p_title),p_description,auth.uid(),'draft',p_entry_deadline,p_scoring_deadline,p_general_slots,p_freshman_slots) RETURNING id INTO v_id;
 FOR v_c IN SELECT value FROM jsonb_array_elements(p_criteria) LOOP
   IF nullif(trim(v_c->>'name'),'') IS NULL OR length(v_c->>'name')>100 OR
      (v_c->>'max_score')::numeric <= 0 OR (v_c->>'max_score')::numeric > 999999 OR
      (v_c->>'weight')::numeric < 0 OR (v_c->>'weight')::numeric > 9999 THEN
     RAISE EXCEPTION '採点項目の値が不正です'; END IF;
   INSERT INTO public.audition_criteria(audition_id,name,max_score,weight,sort_order)
   VALUES(v_id, v_c->>'name',(v_c->>'max_score')::numeric,(v_c->>'weight')::numeric,v_count);
   v_count := v_count+1;
 END LOOP;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.audition_change_status(p_audition_id uuid,p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_old text; v_entry timestamptz;
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ操作できます'; END IF;
 SELECT status,entry_deadline INTO v_old,v_entry FROM public.auditions WHERE id=p_audition_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '対象がありません'; END IF;
 IF NOT ((v_old='draft' AND p_status='open') OR
         (v_old='open' AND p_status='scoring') OR
         (v_old='scoring' AND p_status='closed') OR
         (v_old='closed' AND p_status='published')) THEN RAISE EXCEPTION '状態の変更順序が不正です'; END IF;
 IF v_old='open' AND now()<v_entry THEN RAISE EXCEPTION 'エントリー締切前です'; END IF;
 IF p_status='published' AND EXISTS(SELECT 1 FROM public.audition_results r JOIN public.audition_entries e ON e.id=r.entry_id WHERE e.audition_id=p_audition_id AND r.passed IS NULL) THEN RAISE EXCEPTION '全バンドの合否を決定してください'; END IF;
 IF p_status='published' AND NOT EXISTS(SELECT 1 FROM public.audition_results r JOIN public.audition_entries e ON e.id=r.entry_id WHERE e.audition_id=p_audition_id) THEN
   RAISE EXCEPTION '先に結果を集計してください'; END IF;
 UPDATE public.auditions SET status=p_status,updated_at=now() WHERE id=p_audition_id;
END $$;

CREATE OR REPLACE FUNCTION public.audition_register(p_audition_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.auditions WHERE id=p_audition_id AND status='open' AND now()<entry_deadline) THEN RAISE EXCEPTION '参加登録期間外です'; END IF;
 INSERT INTO public.audition_participants(audition_id,user_id) VALUES(p_audition_id,auth.uid()) ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public.audition_enter(p_audition_id uuid,p_band_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_fresh boolean;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.auditions WHERE id=p_audition_id AND status='open' AND now()<entry_deadline) THEN RAISE EXCEPTION 'エントリー期間外です'; END IF;
 IF NOT public.is_band_member(p_band_id) THEN RAISE EXCEPTION '所属バンドのみエントリーできます'; END IF;
 -- First-year band: all current members admitted in the current calendar year.
 SELECT coalesce(bool_and(coalesce(p.year_override,p.admission_year)=extract(year from current_date)::integer),false)
 INTO v_fresh FROM public.band_members bm JOIN public.profiles p ON p.id=bm.user_id WHERE bm.band_id=p_band_id;
 INSERT INTO public.audition_entries(audition_id,band_id,entered_by,is_freshman_band)
 VALUES(p_audition_id,p_band_id,auth.uid(),v_fresh)
 ON CONFLICT(audition_id,band_id) DO UPDATE SET band_id=EXCLUDED.band_id RETURNING id INTO v_id;
 -- Snapshot membership for historical feedback access and own-band exclusion.
 DELETE FROM public.audition_entry_members WHERE entry_id=v_id;
 INSERT INTO public.audition_entry_members(entry_id,user_id)
 SELECT v_id,user_id FROM public.band_members WHERE band_id=p_band_id;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.audition_save_review(p_entry_id uuid,p_scores jsonb,p_comment text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_audition uuid; v_c record; v_score numeric; v_n integer := 0;
BEGIN
 SELECT e.audition_id INTO v_audition FROM public.audition_entries e JOIN public.auditions a ON a.id=e.audition_id
 WHERE e.id=p_entry_id AND a.status='scoring' AND (a.scoring_deadline IS NULL OR now()<=a.scoring_deadline);
 IF v_audition IS NULL THEN RAISE EXCEPTION '採点期間外です'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.audition_participants WHERE audition_id=v_audition AND user_id=auth.uid()) THEN RAISE EXCEPTION '参加登録した人のみ採点できます'; END IF;
 IF EXISTS(SELECT 1 FROM public.audition_entry_members WHERE entry_id=p_entry_id AND user_id=auth.uid()) THEN RAISE EXCEPTION '自分のバンドは採点できません'; END IF;
 IF p_comment IS NOT NULL AND length(p_comment)>3000 THEN RAISE EXCEPTION '感想は3000文字以内です'; END IF;
 IF jsonb_typeof(p_scores) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION '採点データが不正です'; END IF;
 FOR v_c IN SELECT id,max_score FROM public.audition_criteria WHERE audition_id=v_audition LOOP
   IF NOT p_scores ? (v_c.id::text) THEN RAISE EXCEPTION '未入力の採点項目があります'; END IF;
   v_score := (p_scores->>(v_c.id::text))::numeric;
   IF v_score<0 OR v_score>v_c.max_score OR v_score<>trunc(v_score) THEN RAISE EXCEPTION '点数は満点以内の整数で入力してください'; END IF;
   INSERT INTO public.audition_scores(audition_id,entry_id,criterion_id,judge_id,score,comment)
   VALUES(v_audition,p_entry_id,v_c.id,auth.uid(),v_score,NULL)
   ON CONFLICT(entry_id,criterion_id,judge_id) DO UPDATE SET score=EXCLUDED.score,updated_at=now();
   v_n := v_n+1;
 END LOOP;
 IF v_n=0 OR (SELECT count(*) FROM jsonb_object_keys(p_scores))<>v_n THEN RAISE EXCEPTION '採点項目が不正です'; END IF;
 -- Store one comment per judge and entry, on the first criterion row.
 UPDATE public.audition_scores SET comment=nullif(trim(p_comment),'')
 WHERE entry_id=p_entry_id AND judge_id=auth.uid()
 AND criterion_id=(SELECT id FROM public.audition_criteria WHERE audition_id=v_audition ORDER BY sort_order,id LIMIT 1);
END $$;

CREATE OR REPLACE FUNCTION public.audition_finalize(p_audition_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_status text;
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ操作できます'; END IF;
 SELECT status INTO v_status FROM public.auditions WHERE id=p_audition_id FOR UPDATE;
 IF v_status<>'closed' THEN RAISE EXCEPTION '採点終了後に集計してください'; END IF;
 DELETE FROM public.audition_results WHERE entry_id IN (SELECT id FROM public.audition_entries WHERE audition_id=p_audition_id);
 -- A judge's vote counts only if they scored every criterion of every eligible band.
 WITH eligible AS (
   SELECT p.user_id AS judge_id,e.id AS entry_id,c.id AS criterion_id
   FROM public.audition_participants p
   JOIN public.audition_entries e ON e.audition_id=p.audition_id
   JOIN public.audition_criteria c ON c.audition_id=e.audition_id
   WHERE p.audition_id=p_audition_id
   AND NOT EXISTS(SELECT 1 FROM public.audition_entry_members m WHERE m.entry_id=e.id AND m.user_id=p.user_id)
 ), judge_valid AS (
   SELECT judge_id,bool_and(s.id IS NOT NULL) AS valid
   FROM eligible x LEFT JOIN public.audition_scores s ON s.entry_id=x.entry_id AND s.criterion_id=x.criterion_id AND s.judge_id=x.judge_id
   GROUP BY judge_id
 ), per_entry AS (
   SELECT e.id AS entry_id,
     coalesce(sum(s.score*c.weight) FILTER(WHERE j.valid),0) /
       greatest(count(DISTINCT s.judge_id) FILTER(WHERE j.valid),1) AS total,
     count(DISTINCT s.judge_id) FILTER(WHERE j.valid) AS valid_votes,
     count(DISTINCT s.judge_id) FILTER(WHERE NOT j.valid) AS invalid_votes
   FROM public.audition_entries e
   LEFT JOIN public.audition_scores s ON s.entry_id=e.id
   LEFT JOIN public.audition_criteria c ON c.id=s.criterion_id
   LEFT JOIN judge_valid j ON j.judge_id=s.judge_id
   WHERE e.audition_id=p_audition_id GROUP BY e.id
 ), scored AS (
   SELECT p.entry_id,p.total-coalesce((SELECT sum(points) FROM public.audition_penalties WHERE entry_id=p.entry_id),0) AS total,p.valid_votes,p.invalid_votes
   FROM per_entry p
 ), ranked AS (
   SELECT *,rank() OVER(ORDER BY total DESC) AS overall_rank FROM scored
 )
 INSERT INTO public.audition_results(entry_id,total_score,overall_rank,valid_votes,invalid_votes,calculated_at)
 SELECT entry_id,total,overall_rank,valid_votes,invalid_votes,now() FROM ranked;
 -- Automatic slot assignment is deliberately NOT done: boundary ties require president judgment.
END $$;

-- Safe public summary, no judge-specific scores.
CREATE OR REPLACE FUNCTION public.audition_results_view(p_audition_id uuid)
RETURNS TABLE(entry_id uuid,band_name text,total_score numeric,overall_rank integer,valid_votes integer,passed boolean,result_category text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT e.id,b.name,r.total_score,r.overall_rank,r.valid_votes,r.passed,r.result_category
 FROM public.audition_results r JOIN public.audition_entries e ON e.id=r.entry_id
 JOIN public.bands b ON b.id=e.band_id JOIN public.auditions a ON a.id=e.audition_id
 WHERE e.audition_id=p_audition_id AND (a.status='published' OR public.is_circle_president())
 ORDER BY r.overall_rank,b.name
$$;

-- The president explicitly decides passing results (especially ties and freshman/general slots).
CREATE OR REPLACE FUNCTION public.audition_set_pass(p_entry_id uuid,p_passed boolean,p_category text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ操作できます'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.audition_results r JOIN public.audition_entries e ON e.id=r.entry_id JOIN public.auditions a ON a.id=e.audition_id WHERE r.entry_id=p_entry_id AND a.status='closed') THEN RAISE EXCEPTION '公開前の集計済み結果のみ変更できます'; END IF;
 IF p_passed AND p_category NOT IN ('general','freshman') THEN RAISE EXCEPTION '合格枠が不正です'; END IF;
 UPDATE public.audition_results SET passed=p_passed,result_category=CASE WHEN p_passed THEN p_category ELSE NULL END WHERE entry_id=p_entry_id;
END $$;

CREATE OR REPLACE FUNCTION public.audition_feedback_list()
RETURNS TABLE(entry_id uuid,audition_title text,band_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT e.id,a.title,b.name FROM public.audition_entries e
 JOIN public.auditions a ON a.id=e.audition_id JOIN public.bands b ON b.id=e.band_id
 WHERE a.status='published' AND EXISTS(SELECT 1 FROM public.audition_entry_members m WHERE m.entry_id=e.id AND m.user_id=auth.uid())
 ORDER BY a.created_at DESC,b.name
$$;

CREATE OR REPLACE FUNCTION public.audition_feedback(p_entry_id uuid)
RETURNS TABLE(comment text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.audition_entries e JOIN public.auditions a ON a.id=e.audition_id
   JOIN public.audition_entry_members m ON m.entry_id=e.id WHERE e.id=p_entry_id AND m.user_id=auth.uid() AND a.status='published') THEN
   RAISE EXCEPTION 'この感想を閲覧する権限がありません'; END IF;
 RETURN QUERY SELECT s.comment FROM public.audition_scores s WHERE s.entry_id=p_entry_id AND s.comment IS NOT NULL AND trim(s.comment)<>'' ORDER BY s.updated_at;
END $$;

-- Entry lists and participants are visible only through these RLS policies.
DROP POLICY IF EXISTS audition_entries_select ON public.audition_entries;
CREATE POLICY audition_entries_select ON public.audition_entries FOR SELECT TO authenticated
USING (EXISTS(SELECT 1 FROM public.auditions a WHERE a.id=audition_id));
DROP POLICY IF EXISTS audition_participants_select ON public.audition_participants;
CREATE POLICY audition_participants_select ON public.audition_participants FOR SELECT TO authenticated
USING (user_id=auth.uid() OR public.is_circle_president());

-- PostgreSQL grants function EXECUTE to PUBLIC by default; remove it for all RPCs.
REVOKE ALL ON FUNCTION public.audition_create(text,text,timestamptz,timestamptz,integer,integer,jsonb), public.audition_change_status(uuid,text), public.audition_register(uuid), public.audition_enter(uuid,uuid), public.audition_save_review(uuid,jsonb,text), public.audition_finalize(uuid), public.audition_results_view(uuid), public.audition_set_pass(uuid,boolean,text), public.audition_feedback_list(), public.audition_feedback(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.audition_create(text,text,timestamptz,timestamptz,integer,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_change_status(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_register(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_enter(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_save_review(uuid,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_finalize(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_results_view(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_set_pass(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_feedback_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.audition_feedback(uuid) TO authenticated;
COMMIT;
