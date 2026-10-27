-- Apply after previous setup.sql. Existing data is retained except when explicitly deleted.
BEGIN;

CREATE TABLE IF NOT EXISTS public.audition_invalid_votes (
 audition_id uuid NOT NULL REFERENCES public.auditions(id) ON DELETE CASCADE,
 judge_id uuid NOT NULL REFERENCES public.profiles(id),
 PRIMARY KEY (audition_id,judge_id)
);
ALTER TABLE public.audition_invalid_votes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.audition_invalid_votes FROM anon,authenticated;

CREATE OR REPLACE FUNCTION public.audition_judges(p_audition_id uuid)
RETURNS TABLE(judge_id uuid,username text,completed bigint,required bigint,is_invalid boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ閲覧できます'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.auditions WHERE id=p_audition_id AND status='closed') THEN RAISE EXCEPTION '採点終了後のみ操作できます'; END IF;
 RETURN QUERY
 WITH judges AS (SELECT DISTINCT s.judge_id FROM public.audition_scores s WHERE s.audition_id=p_audition_id),
 eligible AS (
 SELECT j.judge_id,e.id AS entry_id,c.id AS criterion_id
 FROM judges j JOIN public.audition_entries e ON e.audition_id=p_audition_id
 JOIN public.audition_criteria c ON c.audition_id=p_audition_id
 WHERE NOT EXISTS(SELECT 1 FROM public.audition_entry_members m WHERE m.entry_id=e.id AND m.user_id=j.judge_id)
 )
 SELECT j.judge_id,p.username,
 count(s.id) AS completed,count(x.criterion_id) AS required,
 EXISTS(SELECT 1 FROM public.audition_invalid_votes iv WHERE iv.audition_id=p_audition_id AND iv.judge_id=j.judge_id) AS is_invalid
 FROM judges j JOIN public.profiles p ON p.id=j.judge_id
 LEFT JOIN eligible x ON x.judge_id=j.judge_id
 LEFT JOIN public.audition_scores s ON s.entry_id=x.entry_id AND s.criterion_id=x.criterion_id AND s.judge_id=x.judge_id
 GROUP BY j.judge_id,p.username ORDER BY p.username;
END $$;

CREATE OR REPLACE FUNCTION public.audition_set_invalid_vote(p_audition_id uuid,p_judge_id uuid,p_invalid boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ操作できます'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.auditions WHERE id=p_audition_id AND status='closed') THEN RAISE EXCEPTION '採点終了後のみ操作できます'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.audition_scores WHERE audition_id=p_audition_id AND judge_id=p_judge_id) THEN RAISE EXCEPTION '採点者が存在しません'; END IF;
 IF p_invalid THEN
   INSERT INTO public.audition_invalid_votes(audition_id,judge_id) VALUES(p_audition_id,p_judge_id) ON CONFLICT DO NOTHING;
 ELSE
   DELETE FROM public.audition_invalid_votes WHERE audition_id=p_audition_id AND judge_id=p_judge_id;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.audition_delete(p_audition_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ削除できます'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.auditions WHERE id=p_audition_id) THEN RAISE EXCEPTION '対象がありません'; END IF;
 -- Existing foreign keys on auditions and entries use ON DELETE CASCADE.
 DELETE FROM public.auditions WHERE id=p_audition_id;
END $$;

CREATE OR REPLACE FUNCTION public.audition_create(
 p_title text, p_description text, p_entry_deadline timestamptz,
 p_scoring_deadline timestamptz, p_general_slots integer,
 p_freshman_slots integer, p_criteria jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_c jsonb; v_count integer := 0;
BEGIN
 IF NOT public.is_circle_president() THEN RAISE EXCEPTION '部長のみ作成できます'; END IF;
 IF nullif(trim(p_title),'') IS NULL OR length(p_title)>100 THEN RAISE EXCEPTION 'タイトルが不正です'; END IF;
 IF p_entry_deadline IS NULL THEN RAISE EXCEPTION '締切が不正です'; END IF;
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
CREATE OR REPLACE FUNCTION public.audition_save_review(p_entry_id uuid,p_scores jsonb,p_comment text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_audition uuid; v_c record; v_score numeric; v_n integer := 0;
BEGIN
 SELECT e.audition_id INTO v_audition FROM public.audition_entries e JOIN public.auditions a ON a.id=e.audition_id
 WHERE e.id=p_entry_id AND a.status='scoring';
 IF v_audition IS NULL THEN RAISE EXCEPTION '採点期間外です'; END IF;

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
 IF v_status <> 'closed' THEN RAISE EXCEPTION '採点終了後に集計してください'; END IF;
 DELETE FROM public.audition_results WHERE entry_id IN (SELECT id FROM public.audition_entries WHERE audition_id=p_audition_id);
 WITH judges AS (
   SELECT DISTINCT s.judge_id FROM public.audition_scores s WHERE s.audition_id=p_audition_id
 ), required AS (
   SELECT j.judge_id,e.id AS entry_id,c.id AS criterion_id
   FROM judges j JOIN public.audition_entries e ON e.audition_id=p_audition_id
   JOIN public.audition_criteria c ON c.audition_id=p_audition_id
   WHERE NOT EXISTS (SELECT 1 FROM public.audition_entry_members m WHERE m.entry_id=e.id AND m.user_id=j.judge_id)
 ), judge_valid AS (
   SELECT j.judge_id,
     NOT EXISTS (SELECT 1 FROM required x LEFT JOIN public.audition_scores s
       ON s.entry_id=x.entry_id AND s.criterion_id=x.criterion_id AND s.judge_id=x.judge_id
       WHERE x.judge_id=j.judge_id AND s.id IS NULL)
     AND NOT EXISTS (SELECT 1 FROM public.audition_invalid_votes iv
       WHERE iv.audition_id=p_audition_id AND iv.judge_id=j.judge_id) AS valid
   FROM judges j
 ), judge_entry AS (
   SELECT s.entry_id,s.judge_id,sum(s.score*c.weight) AS points
   FROM public.audition_scores s JOIN public.audition_criteria c ON c.id=s.criterion_id
   WHERE s.audition_id=p_audition_id GROUP BY s.entry_id,s.judge_id
 ), totals AS (
   SELECT e.id AS entry_id,
     coalesce(avg(je.points) FILTER (WHERE j.valid),0) -
       coalesce((SELECT sum(p.points) FROM public.audition_penalties p WHERE p.entry_id=e.id),0) AS total,
     count(je.judge_id) FILTER (WHERE j.valid) AS valid_votes,
     count(je.judge_id) FILTER (WHERE NOT j.valid) AS invalid_votes
   FROM public.audition_entries e
   LEFT JOIN judge_entry je ON je.entry_id=e.id
   LEFT JOIN judge_valid j ON j.judge_id=je.judge_id
   WHERE e.audition_id=p_audition_id GROUP BY e.id
 ), ranked AS (
   SELECT *,rank() OVER(ORDER BY total DESC) AS overall_rank FROM totals
 )
 INSERT INTO public.audition_results(entry_id,total_score,overall_rank,valid_votes,invalid_votes,calculated_at)
 SELECT entry_id,total,overall_rank,valid_votes,invalid_votes,now() FROM ranked;
END $$;
REVOKE ALL ON FUNCTION public.audition_judges(uuid), public.audition_set_invalid_vote(uuid,uuid,boolean), public.audition_delete(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.audition_judges(uuid), public.audition_set_invalid_vote(uuid,uuid,boolean), public.audition_delete(uuid) TO authenticated;
COMMIT;
