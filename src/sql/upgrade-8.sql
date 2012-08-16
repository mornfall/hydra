alter table Jobsets
   add column exprType text not null,
   add column guileExprEntry text;

update Jobsets j set
   exprType = "nix";
