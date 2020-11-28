-- 删除后创建
drop table if exists log cascade ;
drop type if exists log_type cascade ;
drop table if exists signed_users cascade ;
drop table if exists commodities cascade ;
DROP TABLE IF EXISTS products cascade ;
DROP TABLE IF EXISTS makers cascade ;
DROP TABLE IF EXISTS sub_types cascade ;
DROP TABLE IF EXISTS parent_types cascade ;
drop type if exists device_type cascade ;
drop function if exists getDefaultUserKey() cascade;

-- 类型
CREATE TABLE parent_types (
    id SMALLSERIAL PRIMARY KEY NOT NULL,
    name text NOT NULL UNIQUE
);
CREATE TABLE sub_types (
    id   SMALLSERIAL NOT NULL PRIMARY KEY,
    name  TEXT NOT NULL UNIQUE,
    parent_id SMALLINT NOT NULL REFERENCES parent_types (id)
);
-- 厂家
CREATE TABLE makers (
    id   SERIAL NOT NULL PRIMARY KEY,
    name TEXT   NOT NULL UNIQUE
);
-- 产品 写你妈大小写 爬
CREATE TABLE products(
    id serial primary key not null ,
    maker_id int references makers(id),
    name text not null ,
    type_id smallint references sub_types(id)
);
-- 商品
create table commodities (
    id serial not null primary key ,
    barcode int not null unique check ( length(barcode::text) in(7,15) ) ,
    product_id int references products(id),
    price money not null ,
    size text not null ,
    other text not null ,
    insert_time timestamp default now()
);
-- 用户类型
create type device_type as ENUM (
    'android','testing',
    'web','iphone',
    'desktop-client',
    'shit'
);
-- 用户表
create table signed_users(
    key text primary key not null ,
    device_id text unique not null ,
    device_type device_type not null default 'shit',
    isWriteable boolean not null default false,
--     isResigned bool default false not null ,
    signed_time timestamp default now() not null
);
-- 获取默认用户
create or replace function getDefaultUserKey() returns text as $$
    declare
        results text :='None' ;
    begin
        select key into results from signed_users where device_id = 'None_Master_';
        return results;
    end;
    $$ language plpgsql;
-- 默认用户
insert into signed_users(key, device_id,isWriteable) values (md5(random()::text)::text,'None_Master_',true);
-- 检查写入权限 --
create or replace function writeable(kie text) returns Boolean as $$
declare
    writable boolean ;
begin
    select isWriteable into writable from signed_users where key=kie;
    return  (found and writable) ;
end;
$$ language plpgsql;
-- log专场 --
create type log_type as ENUM ('insert','update','delete','login','didnt_tell_yet');
create table log(
    id serial primary key ,
    user_key text references signed_users(key),
    target_name text not null ,
    content json not null ,
    action log_type not null
--         default 'didnt_tell_yet'
                ,
    log_time timestamp default now() not null
);
-- 日志生成

create or replace procedure login(
    in kie text ,in deviceID text , in deviceType device_type
)  language plpgsql  as $$
declare
    writable bool;
begin
    insert into log(user_key, target_name, content,action)  values (getDefaultUserKey(),'users', concat('{"key":"',kie,'"}') ,'login');
    select isWriteable into writable from signed_users where key = kie;
    -- 如果不存在插入 存在时判断是否可写入 选择更新
    if not found then
        insert into signed_users(key, device_id,device_type,isWriteable) values(kie,deviceID,deviceType,true);
    elseif not writable then
        update signed_users set isWriteable = true where key = kie;
    end if;
end $$;
create or replace procedure log(
    in key text, in targetName text,in contents json,in actions log_type
) as $$
    begin
        if writeable(key) then
            insert into log(user_key, target_name, content,action)
            values (key,targetName,contents,actions);
        else
            raise exception '操作不允许!该用户未经授权!';
        end if;
    end
$$ language plpgsql ;
-- 记录INIT事件
call log(getDefaultUserKey()::text,'all', '{"m":"init"}','didnt_tell_yet'::log_type);
-- TODO : view
-- sub_type insert function
create or replace function insertType(key1 text ,parent1 text,sub text,insertAll bool) returns smallint as
    $$declare
        parentID int;
    begin
        -- 如果不可写入时阻断
        if not writeable(key1) then return 401;end if;
        -- 查找
        select id into parentID from parent_types where name = parent1 ;
        --找不到
        if not FOUND then
            -- 不需要插入直接报错
            if not insertAll then
                return 404;
            else
                -- 插入log
                call log(key1,'parent_types',concat('{"new":"',parent1,'"}')::json,'insert'::log_type);
                -- 插入表并呼唤子类型插入
                return insertType(key1,parent1,sub,false);
            end if;
        else
            -- 插入log
            call log(key1,'sub_types',concat('{"new":"',sub,'"}')::json,'insert'::log_type);
            -- 插入表
            insert into sub_types(name, parent_id) values (sub,parent_id);
            return 200;
        end if;
exception
    when unique_violation then
        return 400;
return 500;end$$ language plpgsql;
-- product insert function
create or replace function insertProduct(keys text ,makerThis text,names text,types text,insertAll bool) returns smallint as
$$declare
    makerID int;
    typeID int;
begin
    -- 如果不可写入时阻断
    if not writeable(keys) then return 401;end if;
    -- 查找 type
    select id into typeID from sub_types where name = typeID ;
    --找不到:插入时往往选择好了类型,现在不需要任何类型插入了
    if not FOUND then return 404; end if;
    -- 查找Maker
    select id into makerID from makers where name == makerThis;
    if not FOUND then
        if not insertAll then return 404;
        else
            -- log
            call log(keys,'makers',concat('{"new":"',makerThis,'"}')::json,'insert'::log_type);
            -- insert into maker
            insert into makers(name) values (makerThis);
            -- return
            return insertProduct(keys,makerThis,names,types,false);
        end if;
    else
        -- 插入log
        call log(keys,'products',concat('{"new":"',names,'"}')::json,'insert'::log_type);
        -- 插入表
        insert into products(maker_id, name, type_id) values (makerID,name,typeID);
        return 200;
    end if;
    return 500;
end$$ language plpgsql;
-- TODO : commodity insert function --复杂度攀升 下次再写 算了 就现在吧 下次一定
-- type update function
create or replace function updateType(key text ,updateParent bool,oldName text,newName text) returns int as $$
    begin
        -- null checking
        if oldName is null or newName is null then return 400;end if;
        -- writable
        if not writeable(key) then return 401;end if;
        if updateParent then
            -- found checking
            if oldName not in(select name from parent_types) then return 404;end if;
            -- log
            call log(key,'parent_types',format('{"old":"%s","new":"%s"}',oldName,newName)::json ,'update');
            -- update
            update parent_types set name=newName where name = oldName;
            return 200;
        else -- update sub type
        -- found checking
            if oldName not in(select name from sub_types) then return 404;end if;
            -- log
            call log(key,'sub_types',format('{"old":"%s","new":"%s"}',oldName,newName)::json ,'update');
            -- update
            update sub_types set name=newName where name = oldName;
            return 200;
        end if;
        return 500;
    end $$ language plpgsql;
-- product update function
create or replace function updateProductByName(key text ,productName text,makerName text,subTypeName text,newName text) returns int as $$
declare
    tmp text;
    tmp_id int;
begin
    -- null checking
    if newName is null and subTypeName is null and makerName is null and productName is null then return 400;end if;
    -- item not in that than jump
    if productName not in(select name from products) then return 404 ; end if;
    -- writable
    if not writeable(key) then return 401;end if;
    -- update makerName
    if makerName is not null then
        -- found check
        select name,id into tmp,tmp_id from makers where name = makerName;
        if not FOUND then return 404 ;end if;
        -- log
        call log(key, 'products', format('{"old":"%s","new":"%s","col":"maker","target":"%s"}',tmp,makerName,productName)::json, 'update'::log_type);
        -- update
        update products set maker_id = tmp_id where name = productName;
    end if;
    -- update type
    if subTypeName is not null then
        -- found check
        select name,id into tmp,tmp_id from sub_types where name = subTypeName;
        if not FOUND then return 404 ;end if;
        -- log
        call log(key, 'products', format('{"old":"%s","new":"%s","col":"type","target":"%s"}',tmp,subTypeName,productName)::json, 'update'::log_type);
        -- update
        update products set type_id = tmp_id where name = productName;
    end if;
    -- update productName
    if subTypeName is not null then
        -- log
        call log(key, 'products', format('{"old":"%s","new":"%s","col":"name"}',productName,newName)::json, 'update'::log_type);
        -- update
        update products set name = newName where name = productName;
    end if;

    return 200;
end $$ language plpgsql;
-- TODO : commodity update function
-- type delete function
create or replace function removeType(key text,parentType bool,typeName text) returns int language plpgsql as $$
    begin
        if not writeable(key) then return 401;end if;
        if not parentType then
            if typeName not in(select name from sub_types) then return 404;end if;
            call log(key,'sub_types', format('{"old":"%s"}',typeName)::json,'delete'::log_type);
            delete from sub_types where name = typeName;
        else
            if typeName not in(select name from parent_types) then return 404;end if;
            call log(key,'parent_types', format('{"old":"%s"}',typeName)::json,'delete'::log_type);
            delete from parent_types where name = typeName;
        end if;
        return 200;
    end;
$$;
-- TODO : product delete function
create or replace function removeProductByName(key text,productName text) returns int language plpgsql as $$
begin
    if not writeable(key) then return 401;end if;
    if productName not in(select name from products) then return 404;end if;
    call log(key,'product_types', format('{"old":"%s"}',productName)::json,'delete'::log_type);
    delete from products where name = productName;
    return 200;
end;$$;

-- TODO : commodity delete function
