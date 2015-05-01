local C = terralib.includec("math.h")

local function newclass(name)
    local mt = { __name = name, variants = terralib.newlist() }
    mt.__index = mt
    function mt:is(obj)
        local omt = getmetatable(obj)
        while omt ~= nil do
            if self == omt then return true end
            omt = omt.__parent
        end
        return false
    end
    function mt:new(obj)
        obj = obj or {}
        setmetatable(obj,self)
        return obj
    end
    function mt:Variant(name)
        local vt = { kind = name, __parent = self }
        for k,v in pairs(self) do
            vt[k] = v
        end
        self.variants:insert(vt)
        vt.__index = vt
        return vt
    end
    setmetatable(mt, { __newindex = function(self,idx,v)
        rawset(self,idx,v)
        for i,j in ipairs(self.variants) do
            rawset(j,idx,v)
        end
    end })
 
    return mt
end

local Op = newclass("Op") -- a primitive operator like + or sin

local Exp = newclass("Exp") -- an expression involving primitives
local Var = Exp:Variant("Var") -- a variable
local Apply = Exp:Variant("Apply") -- an application
local Const = Exp:Variant("Const") -- a constant, C

local empty = terralib.newlist {}
function Exp:children() return empty end
function Apply:children() return self.args end 

function Const:__tostring() return tostring(self.v) end

local applyid = 0
local function newapply(op,args)
    local nvars = 0
    assert(not op.nparams or #args == op.nparams)
    applyid = applyid + 1
    return Apply:new { op = op, args = args, nvars = nvars, id = applyid - 1 }
end

local getconst = terralib.memoize(function(n) return Const:new { v = n } end)
local function toexp(n)
    if n then 
        if Exp:is(n) then return n
        elseif type(n) == "number" then return getconst(n)
        elseif type(n) == "table" then
            local mt = getmetatable(n)
            if mt and type(mt.__toadexp) == "function" then
                return toexp(mt.__toadexp(n))
            end
        end
    end
    return nil
end

local zero,one,negone = toexp(0),toexp(1),toexp(-1)
local function allconst(args)
    for i,a in ipairs(args) do
        if not Const:is(a) then return false end
    end
    return true
end

function Var:key() return self.key_ end

local function shouldcommute(a,b)
    if Const:is(a) then return true end
    if b:prec() < a:prec() then return true end
    return false
end

local commutes = { add = true, mul = true }
local assoc = { add = true, mul = true }
local function factors(e)
    if Apply:is(e) and e.op.name == "mul" then
        return e.args[1],e.args[2]
    end
    return e,one
end
local function simplify(op,args)
    local x,y,z = unpack(args)
    --print(x,y)
    if allconst(args) and op:getimpl() then
        return toexp(op:getimpl()(unpack(args:map("v"))))
    end
    if #args == 2 and Apply:is(x) and Apply:is(y) and x.op.name == "select" and y.op.name == "select" and x.args[1] == y.args[1] then
        return ad.select(x.args[1],op(x.args[2],y.args[2]),op(x.args[3],y.args[3]))
    end
    if assoc[op.name] and Apply:is(x) and x.op.name == op.name
           and Const:is(x.args[2]) then -- (e + c) + ? -> e + (? + c)
        --print("assoc1")
        return op(x.args[1],op(x.args[2],y)) -- e0 + (e1 + c) ->  (e0 + e1) + c
    elseif assoc[op.name] and Apply:is(y) and y.op.name == op.name
           and Const:is(y.args[2]) then
        --print("assoc2")
        return op(op(x,y.args[1]),y.args[2])
    elseif commutes[op.name] and shouldcommute(x,y) then 
        --print("commute")
        return op(y,x) -- constants will be on rhs
    elseif op.name == "mul" then
        if y == one then return x
        elseif y == zero then return zero
        elseif y == negone then return -x
        elseif Apply:is(x) and x.op.name == "select" then
            if x.args[2] == one or x.args[2] == zero or x.args[3] == one or x.args[3] == zero then
                return ad.select(x.args[1],y*x.args[2],y*x.args[3])
            end
        elseif Apply:is(y) and y.op.name == "select" then
            if y.args[2] == one or y.args[2] == zero or y.args[3] == one or y.args[3] == zero then
                return ad.select(y.args[1],x*y.args[2],x*y.args[3])
            end
        elseif Const:is(y) and Apply:is(x) and x.op.name == "unm" then
            return x.args[1]*-y
        end
    elseif op.name == "add" then
        if y == zero then return x 
        end
        local x0,x1 = factors(x)
        local y0,y1 = factors(y)
        if x1 ~= one or y1 ~= one or x0 == y0 then 
            if x0 == y0 then return x0*(x1 + y1)
            elseif x1 == y1 then return (x0 + y0)*x1
            end
        end
    elseif op.name == "sub" then
        if x == y then return zero
        elseif y == zero then return x
        elseif x == zero then return -y 
        end
    elseif op.name == "div" then
        if y == one then return x
        elseif y == negone then return -x
        elseif x == y then return one 
        elseif Const:is(y) then return x*(one/y)
        end
    elseif op.name == "select" and Const:is(x) then
        return  x.v ~= 0 and y or z
    end
    
    
    return newapply(op,args)
end


local getapply = terralib.memoize(function(op,...)
    local args = terralib.newlist {...}
    return simplify(op,args)
end)


local function toexps(...)
    local es = terralib.newlist {}
    for i = 1, select('#',...) do
        es[i] = assert(toexp(select(i,...)),"attempting use a value that is not an expression")
    end
    return es
end
    

-- generates variable names
local v = setmetatable({},{__index = function(self,idx)
    local r = Var:new { key_ = assert(idx) }
    self[idx] = r
    return r
end})

local x,y,z = v[1],v[2],v[3]

local ad = {}
ad.v = v
ad.toexp = toexp
ad.newclass = newclass

setmetatable(ad, { __index = function(self,idx) -- for just this file, auto-generate an op 
    local name = assert(type(idx) == "string" and idx)
    local op = Op:new { name = name }
    rawset(self,idx,op)
    return op
end })

function Op:__call(...)
    local args = toexps(...)
    return getapply(self,unpack(args))
end
function Op:define(fn,...)
    self.nparams = debug.getinfo(fn,"u").nparams
    self.generator = fn
    self.derivs = toexps(...)
    return self
end
function Op:getimpl()
    if self.impl then return self.impl end
    if not self.generator then return nil
    else
        local s = terralib.newlist()
        for i = 1,self.nparams do
            s:insert(symbol(float))
        end
        terra self.impl([s]) return [self.generator(unpack(s))] end
        return self.impl
    end
end

function Op:__tostring() return self.name end

local mo = {"add","sub","mul","div"}
for i,o in ipairs(mo) do
    Exp["__"..o] = function(a,b) return (ad[o])(a,b) end
end
Exp.__unm = function(a) return ad.unm(a) end

function Var:rename(vars)
    local nv = type(vars) == "function" and vars(self:key()) or vars[self:key()] 
    return assert(toexp(nv),
                  ("rename: unknown invalid mapping for variable %s which maps to %s"):format(tostring(self:key()),tostring(nv)))
end
function Const:rename(vars) return self end
function Apply:rename(vars)
    return self.op(unpack(self.args:map("rename",vars)))
end

local function countuses(es)
    local uses = {}
    local function count(e)
        uses[e] = (uses[e] or 0) + 1
        if uses[e] == 1 and e.kind == "Apply" then
            for i,a in ipairs(e.args) do count(a) end
        end
    end
    for i,a in ipairs(es) do count(a) end
    for k,v in pairs(uses) do
       uses[k] = v > 1 or nil
    end
    return uses
end    



local infix = { add = {"+",1}, sub = {"-",1}, mul = {"*",2}, div = {"/",2} }

function Op:prec()
    if not infix[self.name] then return 3
    else return infix[self.name][2] end
end

function Exp:prec()
    if self.kind ~= "Apply" then return 3
    else return self.op:prec() end
end
local function expstostring(es)
    es = (terralib.islist(es) and es) or terralib.newlist(es)
    local n = 0
    local tbl = terralib.newlist()
    local manyuses = countuses(es)
    local emitted = {}
    local function prec(e) return (manyuses[e] and 3) or e:prec() end
    local emit
    local function emitprec(e,p)
        return (prec(e) < p and "(%s)" or "%s"):format(emit(e))
    end
    local function emitapp(e)
        if e.op.name == "unm" then
            return ("-%s"):format(emitprec(e.args[1],3))
        elseif infix[e.op.name] then
            local o,p = unpack(infix[e.op.name])
            return ("%s %s %s"):format(emitprec(e.args[1],p),o,emitprec(e.args[2],p+1))
        else
            return ("%s(%s)"):format(tostring(e.op),e.args:map(emit):concat(","))
        end
    end
    function emit(e)
        if "Var" == e.kind then
            local k = e:key()
            return type(k) == "number" and ("v%d"):format(k) or tostring(e:key()) 
        elseif "Const" == e.kind then
            return tostring(e.v)
        elseif "Apply" == e.kind then
            if emitted[e] then return emitted[e] end
            local exp = emitapp(e)
            if manyuses[e] then
                local r = ("r%d"):format(n)
                n = n + 1
                emitted[e] = r
                tbl:insert(("  %s = %s\n"):format(r,exp))            
                return r
            else
                return exp
            end
            
        end
    end
    local r = es:map(emit)
    r = r:concat(",")
    if #tbl == 0 then return r end
    return ("let\n%sin\n  %s\nend\n"):format(tbl:concat(),r)
end
ad.tostrings = expstostring
function Exp:__tostring()
    return expstostring(terralib.newlist{self})
end

function ad.toterra(es,varmap_) 
    es = terralib.islist(es) and es or terralib.newlist(es)
     --varmap is a function or table mapping keys to what terra code should go there
    local varmap = type(varmap_) == "table" and function(v) return varmap_[v] end or varmap_
    assert(varmap)
    local manyuses = countuses(es)
    local nvars = 0
    local results = terralib.newlist {}
    
    local statements = terralib.newlist()
    local emitted = {}
    local function emit(e)
        if "Var" == e.kind then
            return assert(varmap(e:key()),"no mapping for variable key "..tostring(e:key()))
        elseif "Const" == e.kind then
            return `float(e.v)
        elseif "Apply" == e.kind then
            if emitted[e] then return emitted[e] end
            assert(e.op.generator)
            local exp = e.op.generator(unpack(e.args:map(emit)))
            if manyuses[e] then
                local v = symbol(float,"e")
                emitted[e] = v
                statements:insert(quote var [v] = exp end)
                return v
            else
                return exp
            end
        end
    end
    local tes = es:map(emit)
    return #statements == 0 and (`tes) or quote [statements] in [tes] end
end

function Exp:d(v)
    assert(Var:is(v))
    self.derivs = self.derivs or {}
    local r = self.derivs[v]
    if r then return r end
    r = self:calcd(v)
    self.derivs[v] = r
    return r
end

function Exp:partials()
    return empty
end
function Apply:partials()
    self.partiallist = self.partiallist or self.op.derivs:map("rename",self.args)
    return self.partiallist
end

function Var:calcd(v)
   return self == v and toexp(1) or toexp(0)
end
function Const:calcd(v)
    return toexp(0)
end
function Apply:calcd(v)
    local dargsdv = self.args:map("d",v)
    local dfdargs = self:partials()
    local r
    for i = 1,#self.args do
        local e = dargsdv[i]*dfdargs[i]
        r = (not r and e) or (r + e)
    end
    return r
end

--calc d(thisexpress)/d(exps[1]) ... d(thisexpress)/d(exps[#exps]) (i.e. the gradient of this expression with relation to the inputs) 
function Exp:gradient(exps)
    exps = terralib.islist(exps) and exps or terralib.newlist(exps)
    -- reverse mode ad, work backward from this expression, accumulate stuff.
    local tape = {} -- mapping from exp -> current accumulated derivative
    local postorder = terralib.newlist()
    local function visit(e)
        if tape[e] then return end
        tape[e] = zero
        for i,c in ipairs(e:children()) do visit(c) end
        postorder:insert(e)
    end
    visit(self)
    tape[self] = one -- the reverse ad 'seed'
    for i = #postorder,1,-1 do --reverse post order traversal from self to equation roots, all uses come before defs
        local e = postorder[i]
        local p = e:partials()
        for j,c in ipairs(e:children()) do
            tape[c] = tape[c] + tape[e]*p[j]
        end
    end
    return exps:map(function(e) return tape[e] or zero end)
end

ad.add:define(function(x,y) return `x + y end,1,1)
ad.sub:define(function(x,y) return `x - y end,1,-1)
ad.mul:define(function(x,y) return `x * y end,y,x)
ad.div:define(function(x,y) return `x / y end,1/y,-x/(y*y))
ad.unm:define(function(x) return `-x end, -1)
ad.acos:define(function(x) return `C.acos(x) end, -1.0/ad.sqrt(1.0 - x*x))
ad.acosh:define(function(x) return `C.acosh(x) end, 1.0/ad.sqrt(x*x - 1.0))
ad.asin:define(function(x) return `C.asin(x) end, 1.0/ad.sqrt(1.0 - x*x))
ad.asinh:define(function(x) return `C.asinh(x) end, 1.0/ad.sqrt(x*x + 1.0))
ad.atan:define(function(x) return `C.atan(x) end, 1.0/(x*x + 1.0))
ad.atan2:define(function(x,y) return `C.atan2(x*x+y*y,y) end, y/(x*x+y*y),x/(x*x+y*y))
ad.cos:define(function(x) return `C.cos(x) end, -ad.sin(x))
ad.cosh:define(function(x) return `C.cosh(x) end, ad.sinh(x))
ad.exp:define(function(x) return `C.exp(x) end, ad.exp(x))
ad.log:define(function(x) return `C.log(x) end, 1.0/x)
ad.log10:define(function(x) return `C.log10(x) end, 1.0/(ad.log(10.0)*x))
ad.pow:define(function(x,y) return `C.pow(x,y) end, y*ad.pow(x,y)/x,ad.log(x)*ad.pow(x,y)) 
ad.sin:define(function(x) return `C.sin(x) end, ad.cos(x))
ad.sinh:define(function(x) return `C.sinh(a) end, ad.cosh(x))
ad.sqrt:define(function(x) return `C.sqrt(x) end, 1.0/(2.0*ad.sqrt(x)))
ad.tan:define(function(x) return `C.tan(x) end, 1.0 + ad.tan(x)*ad.tan(x))
ad.tanh:define(function(x) return `C.tanh(x) end, 1.0/(ad.cosh(x)*ad.cosh(x)))
ad.select:define(function(x,y,z) return `terralib.select(bool(x),y,z) end,0,ad.select(x,1,0),ad.select(x,0,1))
ad.eq:define(function(x,y) return `terralib.select(x == y,1.f,0.f) end, 0,0)

ad.less:define(function(x,y) return `float(x < y) end, 0,0)
ad.greater:define(function(x,y) return `float(x > y) end, 0,0)
ad.lesseq:define(function(x,y) return `float(x <= y) end,0,0)
ad.greatereq:define(function(x,y) return `float(x >= y) end,0,0)
ad.not_:define(function(x) return `terralib.select(x == 0.f,1.f,0.f) end, 0)

setmetatable(ad,nil) -- remove special metatable that generates new blank ops
ad.Var,ad.Apply,ad.Const,ad.Exp = Var, Apply, Const, Exp

--[[
local x,y,z = ad.v.x,ad.v.y,ad.v.z
print(expstostring(ad.atan2.derivs))
assert(y == y)
assert(ad.cos == ad.cos)
local r = ad.sin(x) + ad.cos(y) + ad.cos(y)
print(r)
print(expstostring( terralib.newlist { r, r + 1} ))
print(x*-(-y+1)/4)
print(r:rename({x = x+y,y = x+y}))
local e = 2*x*x*x*3 -- - y*x
print((ad.sin(x)*ad.sin(x)):d(x))
print(e:d(x)*3+(4*x)*x)


local w = x*x

local exp = (3*w + 4*w + 3*w*z)

--6x+8x+6xz

-- 7x + (7x + (z*7x

-- 7x + (r1 
print(unpack((3*x*x + x):gradient{x}))
local g = exp:gradient({x,y,z})
print(expstostring(g))
local t = ad.toterra(g,{x = symbol("x"), y = symbol("y"), z = symbol("z")})
t:printpretty()
]]
return ad