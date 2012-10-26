drop table if exists files;
create table files(
  id int auto_increment primary key,
  path varchar(255) unique,
  lang varchar(5),
  timestamp varchar(32),
  size bigint,
  txt mediumtext) CHARACTER SET utf8;
create unique index files_path on files (path(255));
create index files_lang on files (lang);
create fulltext index files_txt on files (txt);

drop table if exists savedsearches;
create table savedsearches(
  words tinytext,
  bool char(1),
  lang varchar(5),
  result mediumblob);
create index savedsearches_words on savedsearches(lang, words(200));
