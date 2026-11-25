-- Droits admin pour modifier stock et prix depuis admin.html
create policy "admin modifie produits" on products for update to authenticated
  using (exists(select 1 from admins a where a.user_id=auth.uid()))
  with check (exists(select 1 from admins a where a.user_id=auth.uid()));
