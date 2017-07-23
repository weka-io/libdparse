// Written in the D programming language

module dparse.parser;

import dparse.lexer;
import dparse.ast;
import dparse.rollback_allocator;
import dparse.stack_buffer;
import std.experimental.allocator.mallocator;
import std.experimental.allocator;
import std.conv;
import std.algorithm;
import std.array;
import std.string : format;

// Uncomment this if you want ALL THE OUTPUT
// Caution: generates 180 megabytes of logging for std.datetime
//version = dparse_verbose;

/**
 * Params:
 *     tokens = the tokens parsed by dparse.lexer
 *     fileName = the name of the file being parsed
 *     messageFunction = a function to call on error or warning messages.
 *         The parameters are the file name, line number, column number,
 *         the error or warning message, and a boolean (true means error, false
 *         means warning).
 * Returns: the parsed module
 */
Module parseModule(const(Token)[] tokens, string fileName, RollbackAllocator* allocator,
    void function(string, size_t, size_t, string, bool) messageFunction = null,
    uint* errorCount = null, uint* warningCount = null)
{
    auto parser = new Parser();
    parser.fileName = fileName;
    parser.tokens = tokens;
    parser.messageFunction = messageFunction;
    parser.allocator = allocator;
    auto mod = parser.parseModule();
    if (warningCount !is null)
        *warningCount = parser.warningCount;
    if (errorCount !is null)
        *errorCount = parser.errorCount;
    return mod;
}

/**
 * D Parser.
 *
 * It is sometimes useful to sub-class Parser to skip over things that are not
 * interesting. For example, DCD skips over function bodies when caching symbols
 * from imported files.
 */
class Parser
{
    /**
     * Parses an AddExpression.
     *
     * $(GRAMMAR $(RULEDEF addExpression):
     *       $(RULE mulExpression)
     *     | $(RULE addExpression) $(LPAREN)$(LITERAL '+') | $(LITERAL'-') | $(LITERAL'~')$(RPAREN) $(RULE mulExpression)
     *     ;)
     */
    ExpressionNode parseAddExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AddExpression, MulExpression,
            tok!"+", tok!"-", tok!"~")();
    }

    /**
     * Parses an AliasDeclaration.
     *
     * $(GRAMMAR $(RULEDEF aliasDeclaration):
     *       $(LITERAL 'alias') $(RULE aliasInitializer) $(LPAREN)$(LITERAL ',') $(RULE aliasInitializer)$(RPAREN)* $(LITERAL ';')
     *     | $(LITERAL 'alias') $(RULE storageClass)* $(RULE type) $(RULE identifierList) $(LITERAL ';')
     *     | $(LITERAL 'alias') $(RULE storageClass)* $(RULE type) $(RULE identifier) $(LITERAL '(') $(RULE parameters) $(LITERAL ')') $(memberFunctionAttribute)* $(LITERAL ';')
     *     ;)
     */
    AliasDeclaration parseAliasDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AliasDeclaration;
        mixin(tokenCheck!"alias");
        node.comment = comment;
        comment = null;

        if (startsWith(tok!"identifier", tok!"=") || startsWith(tok!"identifier", tok!"("))
        {
            StackBuffer initializers;
            do
            {
                if (!initializers.put(parseAliasInitializer()))
                    return null;
                if (currentIs(tok!","))
                    advance();
                else
                    break;
            }
            while (moreTokens());
            ownArray(node.initializers, initializers);
        }
        else
        {
            StackBuffer storageClasses;
            while (moreTokens() && isStorageClass())
                if (!storageClasses.put(parseStorageClass()))
                    return null;
            ownArray(node.storageClasses, storageClasses);
            mixin (parseNodeQ!(`node.type`, `Type`));
            mixin (parseNodeQ!(`node.identifierList`, `IdentifierList`));
            if (currentIs(tok!"("))
            {
                mixin(parseNodeQ!(`node.parameters`, `Parameters`));
                StackBuffer memberFunctionAttributes;
                while (moreTokens() && currentIsMemberFunctionAttribute())
                    if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                        return null;
                ownArray(node.memberFunctionAttributes, memberFunctionAttributes);
            }
        }
        return attachCommentFromSemicolon(node);
    }

    /**
     * Parses an AliasInitializer.
     *
     * $(GRAMMAR $(RULEDEF aliasInitializer):
     *       $(LITERAL Identifier) $(RULE templateParameters)? $(LITERAL '=') $(RULE storageClass)* $(RULE type)
     *     | $(LITERAL Identifier) $(RULE templateParameters)? $(LITERAL '=') $(RULE functionLiteralExpression)
     *     ;)
     */
    AliasInitializer parseAliasInitializer()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AliasInitializer;
        mixin (tokenCheck!(`node.name`, "identifier"));
        if (currentIs(tok!"("))
            mixin (parseNodeQ!(`node.templateParameters`, `TemplateParameters`));
        mixin(tokenCheck!"=");

        bool isFunction()
        {
            if (currentIsOneOf(tok!"function", tok!"delegate", tok!"{"))
                return true;
            if (startsWith(tok!"identifier", tok!"=>"))
                return true;
            if (currentIs(tok!"("))
            {
                const t = peekPastParens();
                if (t !is null)
                {
                    if (t.type == tok!"=>" || t.type == tok!"{"
                            || isMemberFunctionAttribute(t.type))
                        return true;
                }
            }
            return false;
        }

        if (isFunction)
            mixin (parseNodeQ!(`node.functionLiteralExpression`, `FunctionLiteralExpression`));
        else
        {
            StackBuffer storageClasses;
            while (moreTokens() && isStorageClass())
                if (!storageClasses.put(parseStorageClass()))
                    return null;
            ownArray(node.storageClasses, storageClasses);
            mixin (parseNodeQ!(`node.type`, `Type`));
        }
        return node;
    }

    /**
     * Parses an AliasThisDeclaration.
     *
     * $(GRAMMAR $(RULEDEF aliasThisDeclaration):
     *     $(LITERAL 'alias') $(LITERAL Identifier) $(LITERAL 'this') $(LITERAL ';')
     *     ;)
     */
    AliasThisDeclaration parseAliasThisDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AliasThisDeclaration;
        mixin(tokenCheck!"alias");
        mixin(tokenCheck!(`node.identifier`, "identifier"));
        mixin(tokenCheck!"this");
        return attachCommentFromSemicolon(node);
    }

    /**
     * Parses an AlignAttribute.
     *
     * $(GRAMMAR $(RULEDEF alignAttribute):
     *     $(LITERAL 'align') ($(LITERAL '$(LPAREN)') $(RULE AssignExpression) $(LITERAL '$(RPAREN)'))?
     *     ;)
     */
    AlignAttribute parseAlignAttribute()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AlignAttribute;
        expect(tok!"align");
        if (currentIs(tok!"("))
        {
            mixin(tokenCheck!"(");
            mixin(parseNodeQ!("node.assignExpression", "AssignExpression"));
            mixin(tokenCheck!")");
        }
        return node;
    }

    /**
     * Parses an AndAndExpression.
     *
     * $(GRAMMAR $(RULEDEF andAndExpression):
     *       $(RULE orExpression)
     *     | $(RULE andAndExpression) $(LITERAL '&&') $(RULE orExpression)
     *     ;)
     */
    ExpressionNode parseAndAndExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AndAndExpression, OrExpression,
            tok!"&&")();
    }

    /**
     * Parses an AndExpression.
     *
     * $(GRAMMAR $(RULEDEF andExpression):
     *       $(RULE cmpExpression)
     *     | $(RULE andExpression) $(LITERAL '&') $(RULE cmpExpression)
     *     ;)
     */
    ExpressionNode parseAndExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AndExpression, CmpExpression,
            tok!"&")();
    }

    /**
     * Parses an ArgumentList.
     *
     * $(GRAMMAR $(RULEDEF argumentList):
     *     $(RULE assignExpression) ($(LITERAL ',') $(RULE assignExpression)?)*
     *     ;)
     */
    ArgumentList parseArgumentList()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (!moreTokens)
        {
            error("argument list expected instead of EOF");
            return null;
        }
        size_t startLocation = current().index;
        auto node = parseCommaSeparatedRule!(ArgumentList, AssignExpression)(true);
        mixin (nullCheck!`node`);
        node.startLocation = startLocation;
        if (moreTokens) node.endLocation = current().index;
        return node;
    }

    /**
     * Parses Arguments.
     *
     * $(GRAMMAR $(RULEDEF arguments):
     *     $(LITERAL '$(LPAREN)') $(RULE argumentList)? $(LITERAL '$(RPAREN)')
     *     ;)
     */
    Arguments parseArguments()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Arguments;
        mixin(tokenCheck!"(");
        if (!currentIs(tok!")"))
            mixin (parseNodeQ!(`node.argumentList`, `ArgumentList`));
        mixin(tokenCheck!")");
        return node;
    }

    /**
     * Parses an ArrayInitializer.
     *
     * $(GRAMMAR $(RULEDEF arrayInitializer):
     *       $(LITERAL '[') $(LITERAL ']')
     *     | $(LITERAL '[') $(RULE arrayMemberInitialization) ($(LITERAL ',') $(RULE arrayMemberInitialization)?)* $(LITERAL ']')
     *     ;)
     */
    ArrayInitializer parseArrayInitializer()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ArrayInitializer;
        const open = expect(tok!"[");
        mixin (nullCheck!`open`);
        node.startLocation = open.index;
        StackBuffer arrayMemberInitializations;
        while (moreTokens())
        {
            if (currentIs(tok!"]"))
                break;
            if (!arrayMemberInitializations.put(parseArrayMemberInitialization()))
                return null;
            if (currentIs(tok!","))
                advance();
            else
                break;
        }
        ownArray(node.arrayMemberInitializations, arrayMemberInitializations);
        const close = expect(tok!"]");
        mixin (nullCheck!`close`);
        node.endLocation = close.index;
        return node;
    }

    /**
     * Parses an ArrayLiteral.
     *
     * $(GRAMMAR $(RULEDEF arrayLiteral):
     *     $(LITERAL '[') $(RULE argumentList)? $(LITERAL ']')
     *     ;)
     */
    ArrayLiteral parseArrayLiteral()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ArrayLiteral;
        mixin(tokenCheck!"[");
        if (!currentIs(tok!"]"))
            mixin (parseNodeQ!(`node.argumentList`, `ArgumentList`));
        mixin(tokenCheck!"]");
        return node;
    }

    /**
     * Parses an ArrayMemberInitialization.
     *
     * $(GRAMMAR $(RULEDEF arrayMemberInitialization):
     *     ($(RULE assignExpression) $(LITERAL ':'))? $(RULE nonVoidInitializer)
     *     ;)
     */
    ArrayMemberInitialization parseArrayMemberInitialization()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ArrayMemberInitialization;
        switch (current.type)
        {
        case tok!"[":
            immutable b = setBookmark();
            skipBrackets();
            if (currentIs(tok!":"))
            {
                mixin (parseNodeQ!(`node.assignExpression`, `AssignExpression`));
                advance(); // :
                mixin (parseNodeQ!(`node.nonVoidInitializer`, `NonVoidInitializer`));
                break;
            }
            else
            {
                goToBookmark(b);
                goto case;
            }
        case tok!"{":
            mixin (parseNodeQ!(`node.nonVoidInitializer`, `NonVoidInitializer`));
            break;
        default:
            auto assignExpression = parseAssignExpression();
            mixin (nullCheck!`assignExpression`);
            if (currentIs(tok!":"))
            {
                node.assignExpression = assignExpression;
                advance();
                mixin(parseNodeQ!(`node.nonVoidInitializer`, `NonVoidInitializer`));
            }
            else
            {
                node.nonVoidInitializer = allocator.make!NonVoidInitializer;
                node.nonVoidInitializer.assignExpression = assignExpression;
            }
        }
        return node;
    }

    /**
     * Parses an AsmAddExp
     *
     * $(GRAMMAR $(RULEDEF asmAddExp):
     *       $(RULE asmMulExp)
     *     | $(RULE asmAddExp) ($(LITERAL '+') | $(LITERAL '-')) $(RULE asmMulExp)
     *     ;)
     */
    ExpressionNode parseAsmAddExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmAddExp, AsmMulExp,
            tok!"+", tok!"-")();
    }

    /**
     * Parses an AsmAndExp
     *
     * $(GRAMMAR $(RULEDEF asmAndExp):
     *       $(RULE asmEqualExp)
     *     | $(RULE asmAndExp) $(LITERAL '&') $(RULE asmEqualExp)
     *     ;)
     */
    ExpressionNode parseAsmAndExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmAndExp, AsmEqualExp, tok!"&");
    }

    /**
     * Parses an AsmBrExp
     *
     * $(GRAMMAR $(RULEDEF asmBrExp):
     *       $(RULE asmUnaExp)
     *     | $(RULE asmBrExp)? $(LITERAL '[') $(RULE asmExp) $(LITERAL ']')
     *     ;)
     */
    AsmBrExp parseAsmBrExp()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        AsmBrExp node = allocator.make!AsmBrExp();
        size_t line = current.line;
        size_t column = current.column;
        if (currentIs(tok!"["))
        {
            advance(); // [
            mixin (parseNodeQ!(`node.asmExp`, `AsmExp`));
            mixin(tokenCheck!"]");
            if (currentIs(tok!"["))
                goto brLoop;
        }
        else
        {
            mixin(parseNodeQ!(`node.asmUnaExp`, `AsmUnaExp`));
            brLoop: while (currentIs(tok!"["))
            {
                AsmBrExp br = allocator.make!AsmBrExp(); // huehuehuehue
                br.asmBrExp = node;
                br.line = current().line;
                br.column = current().column;
                node = br;
                node.line = line;
                node.column = column;
                advance(); // [
                mixin(parseNodeQ!(`node.asmExp`, `AsmExp`));
                mixin(tokenCheck!"]");
            }
        }
        return node;
    }

    /**
     * Parses an AsmEqualExp
     *
     * $(GRAMMAR $(RULEDEF asmEqualExp):
     *       $(RULE asmRelExp)
     *     | $(RULE asmEqualExp) ('==' | '!=') $(RULE asmRelExp)
     *     ;)
     */
    ExpressionNode parseAsmEqualExp()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmEqualExp, AsmRelExp, tok!"==", tok!"!=")();
    }

    /**
     * Parses an AsmExp
     *
     * $(GRAMMAR $(RULEDEF asmExp):
     *     $(RULE asmLogOrExp) ($(LITERAL '?') $(RULE asmExp) $(LITERAL ':') $(RULE asmExp))?
     *     ;)
     */
    ExpressionNode parseAsmExp()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        AsmExp node = allocator.make!AsmExp;
        mixin(parseNodeQ!(`node.left`, `AsmLogOrExp`));
        if (currentIs(tok!"?"))
        {
            advance();
            mixin(parseNodeQ!(`node.middle`, `AsmExp`));
            mixin(tokenCheck!":");
            mixin(parseNodeQ!(`node.right`, `AsmExp`));
        }
        return node;
    }

    /**
     * Parses an AsmInstruction
     *
     * $(GRAMMAR $(RULEDEF asmInstruction):
     *       $(LITERAL Identifier)
     *     | $(LITERAL 'align') $(LITERAL IntegerLiteral)
     *     | $(LITERAL 'align') $(LITERAL Identifier)
     *     | $(LITERAL Identifier) $(LITERAL ':') $(RULE asmInstruction)
     *     | $(LITERAL Identifier) $(RULE operands)
     *     | $(LITERAL 'in') $(RULE operands)
     *     | $(LITERAL 'out') $(RULE operands)
     *     | $(LITERAL 'int') $(RULE operands)
     *     ;)
     */
    AsmInstruction parseAsmInstruction()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        AsmInstruction node = allocator.make!AsmInstruction;
        if (currentIs(tok!"align"))
        {
            advance(); // align
            node.hasAlign = true;
            if (currentIsOneOf(tok!"intLiteral", tok!"identifier"))
                node.identifierOrIntegerOrOpcode = advance();
            else
                error("Identifier or integer literal expected.");
        }
        else if (currentIsOneOf(tok!"identifier", tok!"in", tok!"out", tok!"int"))
        {
            node.identifierOrIntegerOrOpcode = advance();
            if (node.identifierOrIntegerOrOpcode == tok!"identifier" && currentIs(tok!":"))
            {
                advance(); // :
                mixin(parseNodeQ!(`node.asmInstruction`, `AsmInstruction`));
            }
            else if (!currentIs(tok!";"))
                mixin(parseNodeQ!(`node.operands`, `Operands`));
        }
        return node;
    }

    /**
     * Parses an AsmLogAndExp
     *
     * $(GRAMMAR $(RULEDEF asmLogAndExp):
     *     $(RULE asmOrExp)
     *     $(RULE asmLogAndExp) $(LITERAL '&&') $(RULE asmOrExp)
     *     ;)
     */
    ExpressionNode parseAsmLogAndExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmLogAndExp, AsmOrExp, tok!"&&");
    }

    /**
     * Parses an AsmLogOrExp
     *
     * $(GRAMMAR $(RULEDEF asmLogOrExp):
     *       $(RULE asmLogAndExp)
     *     | $(RULE asmLogOrExp) '||' $(RULE asmLogAndExp)
     *     ;)
     */
    ExpressionNode parseAsmLogOrExp()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmLogOrExp, AsmLogAndExp, tok!"||")();
    }

    /**
     * Parses an AsmMulExp
     *
     * $(GRAMMAR $(RULEDEF asmMulExp):
     *       $(RULE asmBrExp)
     *     | $(RULE asmMulExp) ($(LITERAL '*') | $(LITERAL '/') | $(LITERAL '%')) $(RULE asmBrExp)
     *     ;)
     */
    ExpressionNode parseAsmMulExp()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmMulExp, AsmBrExp, tok!"*", tok!"/", tok!"%")();
    }

    /**
     * Parses an AsmOrExp
     *
     * $(GRAMMAR $(RULEDEF asmOrExp):
     *       $(RULE asmXorExp)
     *     | $(RULE asmOrExp) $(LITERAL '|') $(RULE asmXorExp)
     *     ;)
     */
    ExpressionNode parseAsmOrExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmOrExp, AsmXorExp, tok!"|")();
    }

    /**
     * Parses an AsmPrimaryExp
     *
     * $(GRAMMAR $(RULEDEF asmPrimaryExp):
     *       $(LITERAL IntegerLiteral)
     *     | $(LITERAL FloatLiteral)
     *     | $(LITERAL StringLiteral)
     *     | $(RULE register)
     *     | $(RULE register : AsmExp)
     *     | $(RULE identifierChain)
     *     | $(LITERAL '$')
     *     ;)
     */
    AsmPrimaryExp parseAsmPrimaryExp()
    {
        import std.range : assumeSorted;
        mixin (traceEnterAndExit!(__FUNCTION__));
        AsmPrimaryExp node = allocator.make!AsmPrimaryExp();
        switch (current().type)
        {
        case tok!"doubleLiteral":
        case tok!"floatLiteral":
        case tok!"intLiteral":
        case tok!"longLiteral":
        case tok!"stringLiteral":
        case tok!"$":
            node.token = advance();
            break;
        case tok!"identifier":
            if (assumeSorted(REGISTER_NAMES).equalRange(current().text).length > 0)
            {
                trace("Found register");
                mixin (nullCheck!`(node.register = parseRegister())`);
                if (current.type == tok!":")
                {
                    advance();
                    mixin(parseNodeQ!(`node.segmentOverrideSuffix`, `AsmExp`));
                }
            }
            else
                mixin(parseNodeQ!(`node.identifierChain`, `IdentifierChain`));
            break;
        default:
            error("Float literal, integer literal, $, or identifier expected.");
            return null;
        }
        return node;
    }

    /**
     * Parses an AsmRelExp
     *
     * $(GRAMMAR $(RULEDEF asmRelExp):
     *       $(RULE asmShiftExp)
     *     | $(RULE asmRelExp) (($(LITERAL '<') | $(LITERAL '<=') | $(LITERAL '>') | $(LITERAL '>=')) $(RULE asmShiftExp))?
     *     ;)
     */
    ExpressionNode parseAsmRelExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmRelExp, AsmShiftExp, tok!"<",
            tok!"<=", tok!">", tok!">=")();
    }

    /**
     * Parses an AsmShiftExp
     *
     * $(GRAMMAR $(RULEDEF asmShiftExp):
     *     $(RULE asmAddExp)
     *     $(RULE asmShiftExp) ($(LITERAL '<<') | $(LITERAL '>>') | $(LITERAL '>>>')) $(RULE asmAddExp)
     *     ;)
     */
    ExpressionNode parseAsmShiftExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmShiftExp, AsmAddExp, tok!"<<",
            tok!">>", tok!">>>");
    }

    /**
     * Parses an AsmStatement
     *
     * $(GRAMMAR $(RULEDEF asmStatement):
     *     $(LITERAL 'asm') $(RULE functionAttributes)? $(LITERAL '{') $(RULE asmInstruction)+ $(LITERAL '}')
     *     ;)
     */
    AsmStatement parseAsmStatement()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        AsmStatement node = allocator.make!AsmStatement;
        advance(); // asm
        StackBuffer functionAttributes;
        while (isAttribute())
        {
            if (!functionAttributes.put(parseFunctionAttribute()))
            {
                error("Function attribute or '{' expected");
                return null;
            }
        }
        ownArray(node.functionAttributes, functionAttributes);
        advance(); // {
        StackBuffer instructions;
        while (moreTokens() && !currentIs(tok!"}"))
        {
            auto c = allocator.setCheckpoint();
            if (!instructions.put(parseAsmInstruction()))
                allocator.rollback(c);
            else
                expect(tok!";");
        }
        ownArray(node.asmInstructions, instructions);
        expect(tok!"}");
        return node;
    }

    /**
     * Parses an AsmTypePrefix
     *
     * Note that in the following grammar definition the first identifier must
     * be "near", "far", "word", "dword", or "qword". The second identifier must
     * be "ptr".
     *
     * $(GRAMMAR $(RULEDEF asmTypePrefix):
     *       $(LITERAL Identifier) $(LITERAL Identifier)?
     *     | $(LITERAL 'byte') $(LITERAL Identifier)?
     *     | $(LITERAL 'short') $(LITERAL Identifier)?
     *     | $(LITERAL 'int') $(LITERAL Identifier)?
     *     | $(LITERAL 'float') $(LITERAL Identifier)?
     *     | $(LITERAL 'double') $(LITERAL Identifier)?
     *     | $(LITERAL 'real') $(LITERAL Identifier)?
     *     ;)
     */
    AsmTypePrefix parseAsmTypePrefix()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        switch (current().type)
        {
        case tok!"identifier":
        case tok!"byte":
        case tok!"short":
        case tok!"int":
        case tok!"float":
        case tok!"double":
        case tok!"real":
            AsmTypePrefix node = allocator.make!AsmTypePrefix();
            node.left = advance();
            if (node.left.type == tok!"identifier") switch (node.left.text)
            {
            case "near":
            case "far":
            case "word":
            case "dword":
            case "qword":
                break;
            default:
                error("ASM type node expected");
                return null;
            }
            if (currentIs(tok!"identifier") && current().text == "ptr")
                node.right = advance();
            return node;
        default:
            error("Expected an identifier, 'byte', 'short', 'int', 'float', 'double', or 'real'");
            return null;
        }
    }

    /**
     * Parses an AsmUnaExp
     *
     * $(GRAMMAR $(RULEDEF asmUnaExp):
     *       $(RULE asmTypePrefix) $(RULE asmExp)
     *     | $(LITERAL Identifier) $(RULE asmExp)
     *     | $(LITERAL '+') $(RULE asmUnaExp)
     *     | $(LITERAL '-') $(RULE asmUnaExp)
     *     | $(LITERAL '!') $(RULE asmUnaExp)
     *     | $(LITERAL '~') $(RULE asmUnaExp)
     *     | $(RULE asmPrimaryExp)
     *     ;)
     */
    AsmUnaExp parseAsmUnaExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        AsmUnaExp node = allocator.make!AsmUnaExp();
        switch (current().type)
        {
        case tok!"+":
        case tok!"-":
        case tok!"!":
        case tok!"~":
            node.prefix = advance();
            mixin(parseNodeQ!(`node.asmUnaExp`, `AsmUnaExp`));
            break;
        case tok!"byte":
        case tok!"short":
        case tok!"int":
        case tok!"float":
        case tok!"double":
        case tok!"real":
        typePrefix:
            mixin(parseNodeQ!(`node.asmTypePrefix`, `AsmTypePrefix`));
            mixin(parseNodeQ!(`node.asmExp`, `AsmExp`));
            break;
        case tok!"identifier":
            switch (current().text)
            {
            case "offsetof":
            case "seg":
                node.prefix = advance();
                mixin(parseNodeQ!(`node.asmExp`, `AsmExp`));
                break;
            case "near":
            case "far":
            case "word":
            case "dword":
            case "qword":
                goto typePrefix;
            default:
                goto outerDefault;
            }
            break;
        outerDefault:
        default:
            mixin(parseNodeQ!(`node.asmPrimaryExp`, `AsmPrimaryExp`));
            break;
        }
        return node;
    }

    /**
     * Parses an AsmXorExp
     *
     * $(GRAMMAR $(RULEDEF asmXorExp):
     *       $(RULE asmAndExp)
     *     | $(RULE asmXorExp) $(LITERAL '^') $(RULE asmAndExp)
     *     ;)
     */
    ExpressionNode parseAsmXorExp()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(AsmXorExp, AsmAndExp, tok!"^")();
    }

    /**
     * Parses an AssertExpression
     *
     * $(GRAMMAR $(RULEDEF assertExpression):
     *     $(LITERAL 'assert') $(LITERAL '$(LPAREN)') $(RULE assignExpression) ($(LITERAL ',') $(RULE assignExpression))? $(LITERAL ',')? $(LITERAL '$(RPAREN)')
     *     ;)
     */
    AssertExpression parseAssertExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AssertExpression;
        node.line = current.line;
        node.column = current.column;
        advance(); // "assert"
        mixin(tokenCheck!"(");
        mixin(parseNodeQ!(`node.assertion`, `AssignExpression`));
        if (currentIs(tok!","))
        {
            advance();
            if (currentIs(tok!")"))
            {
                advance();
                return node;
            }
            mixin(parseNodeQ!(`node.message`, `AssignExpression`));
        }
        if (currentIs(tok!","))
            advance();
        mixin(tokenCheck!")");
        return node;
    }

    /**
     * Parses an AssignExpression
     *
     * $(GRAMMAR $(RULEDEF assignExpression):
     *     $(RULE ternaryExpression) ($(RULE assignOperator) $(RULE assignExpression))?
     *     ;
     *$(RULEDEF assignOperator):
     *       $(LITERAL '=')
     *     | $(LITERAL '>>>=')
     *     | $(LITERAL '>>=')
     *     | $(LITERAL '<<=')
     *     | $(LITERAL '+=')
     *     | $(LITERAL '-=')
     *     | $(LITERAL '*=')
     *     | $(LITERAL '%=')
     *     | $(LITERAL '&=')
     *     | $(LITERAL '/=')
     *     | $(LITERAL '|=')
     *     | $(LITERAL '^^=')
     *     | $(LITERAL '^=')
     *     | $(LITERAL '~=')
     *     ;)
     */
    ExpressionNode parseAssignExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (!moreTokens)
        {
            error("Assign expression expected instead of EOF");
            return null;
        }
        auto ternary = parseTernaryExpression();
        if (ternary is null)
            return null;
        if (currentIsOneOf(tok!"=", tok!">>>=",
            tok!">>=", tok!"<<=",
            tok!"+=", tok!"-=", tok!"*=",
            tok!"%=", tok!"&=", tok!"/=",
            tok!"|=", tok!"^^=", tok!"^=",
            tok!"~="))
        {
            auto node = allocator.make!AssignExpression;
            node.line = current().line;
            node.column = current().column;
            node.ternaryExpression = ternary;
            node.operator = advance().type;
            mixin(parseNodeQ!(`node.expression`, `AssignExpression`));
            return node;
        }
        return ternary;
    }

    /**
     * Parses an AssocArrayLiteral
     *
     * $(GRAMMAR $(RULEDEF assocArrayLiteral):
     *     $(LITERAL '[') $(RULE keyValuePairs) $(LITERAL ']')
     *     ;)
     */
    AssocArrayLiteral parseAssocArrayLiteral()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin (simpleParse!(AssocArrayLiteral, tok!"[",
            "keyValuePairs|parseKeyValuePairs", tok!"]"));
    }

    /**
     * Parses an AtAttribute
     *
     * $(GRAMMAR $(RULEDEF atAttribute):
     *       $(LITERAL '@') $(LITERAL Identifier)
     *     | $(LITERAL '@') $(LITERAL Identifier) $(LITERAL '$(LPAREN)') $(RULE argumentList)? $(LITERAL '$(RPAREN)')
     *     | $(LITERAL '@') $(LITERAL '$(LPAREN)') $(RULE argumentList) $(LITERAL '$(RPAREN)')
     *     | $(LITERAL '@') $(RULE TemplateInstance)
     *     ;)
     */
    AtAttribute parseAtAttribute()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AtAttribute;
        const start = expect(tok!"@");
        mixin (nullCheck!`start`);
        if (!moreTokens)
        {
            error(`"(", or identifier expected`);
            return null;
        }
        node.startLocation = start.index;
        switch (current.type)
        {
        case tok!"identifier":
            if (peekIs(tok!"!"))
                mixin(parseNodeQ!(`node.templateInstance`, `TemplateInstance`));
            else
                node.identifier = advance();
            if (currentIs(tok!"("))
            {
                advance(); // (
                if (!currentIs(tok!")"))
                    mixin(parseNodeQ!(`node.argumentList`, `ArgumentList`));
                expect(tok!")");
            }
            break;
        case tok!"(":
            advance();
            mixin(parseNodeQ!(`node.argumentList`, `ArgumentList`));
            expect(tok!")");
            break;
        default:
            error(`"(", or identifier expected`);
            return null;
        }
        if (moreTokens) node.endLocation = current().index;
        return node;
    }

    /**
     * Parses an Attribute
     *
     * $(GRAMMAR $(RULEDEF attribute):
     *     | $(RULE pragmaExpression)
     *     | $(RULE alignAttribute)
     *     | $(RULE deprecated)
     *     | $(RULE atAttribute)
     *     | $(RULE linkageAttribute)
     *     | $(LITERAL 'export')
     *     | $(LITERAL 'package') ($(LITERAL "(") $(RULE identifierChain) $(LITERAL ")"))?
     *     | $(LITERAL 'private')
     *     | $(LITERAL 'protected')
     *     | $(LITERAL 'public')
     *     | $(LITERAL 'static')
     *     | $(LITERAL 'extern')
     *     | $(LITERAL 'abstract')
     *     | $(LITERAL 'final')
     *     | $(LITERAL 'override')
     *     | $(LITERAL 'synchronized')
     *     | $(LITERAL 'auto')
     *     | $(LITERAL 'scope')
     *     | $(LITERAL 'const')
     *     | $(LITERAL 'immutable')
     *     | $(LITERAL 'inout')
     *     | $(LITERAL 'shared')
     *     | $(LITERAL '__gshared')
     *     | $(LITERAL 'nothrow')
     *     | $(LITERAL 'pure')
     *     | $(LITERAL 'ref')
     *     ;)
     */
    Attribute parseAttribute()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Attribute;
        switch (current.type)
        {
        case tok!"pragma":
            mixin(parseNodeQ!(`node.pragmaExpression`, `PragmaExpression`));
            break;
        case tok!"deprecated":
            mixin(parseNodeQ!(`node.deprecated_`, `Deprecated`));
            break;
        case tok!"align":
            mixin(parseNodeQ!(`node.alignAttribute`, `AlignAttribute`));
            break;
        case tok!"@":
            mixin(parseNodeQ!(`node.atAttribute`, `AtAttribute`));
            break;
        case tok!"package":
            node.attribute = advance();
            if (currentIs(tok!"("))
            {
                expect(tok!"(");
                mixin(parseNodeQ!(`node.identifierChain`, `IdentifierChain`));
                expect(tok!")");
            }
            break;
        case tok!"extern":
            if (peekIs(tok!"("))
            {
                mixin(parseNodeQ!(`node.linkageAttribute`, `LinkageAttribute`));
                break;
            }
            else
                goto case;
        case tok!"private":
        case tok!"protected":
        case tok!"public":
        case tok!"export":
        case tok!"static":
        case tok!"abstract":
        case tok!"final":
        case tok!"override":
        case tok!"synchronized":
        case tok!"auto":
        case tok!"scope":
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
        case tok!"__gshared":
        case tok!"nothrow":
        case tok!"pure":
        case tok!"ref":
            node.attribute = advance();
            break;
        default:
            return null;
        }
        return node;
    }

    /**
     * Parses an AttributeDeclaration
     *
     * $(GRAMMAR $(RULEDEF attributeDeclaration):
     *     $(RULE attribute) $(LITERAL ':')
     *     ;)
     */
    AttributeDeclaration parseAttributeDeclaration(Attribute attribute = null)
    {
        auto node = allocator.make!AttributeDeclaration;
        node.line = current.line;
        node.attribute = attribute is null ? parseAttribute() : attribute;
        expect(tok!":");
        return node;
    }

    /**
     * Parses an AutoDeclaration
     *
     * $(GRAMMAR $(RULEDEF autoDeclaration):
     *     $(RULE storageClass)+  $(RULE autoDeclarationPart) ($(LITERAL ',') $(RULE autoDeclarationPart))* $(LITERAL ';')
     *     ;)
     */
    AutoDeclaration parseAutoDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AutoDeclaration;
        node.comment = comment;
        comment = null;
        StackBuffer storageClasses;
        while (isStorageClass())
            if (!storageClasses.put(parseStorageClass()))
                return null;
        ownArray(node.storageClasses, storageClasses);
        StackBuffer parts;
        do
        {
            if (!parts.put(parseAutoDeclarationPart()))
                return null;
            if (currentIs(tok!","))
                advance();
            else
                break;
        } while (moreTokens());
        ownArray(node.parts, parts);
        return attachCommentFromSemicolon(node);
    }

    /**
     * Parses an AutoDeclarationPart
     *
     * $(GRAMMAR $(RULEDEF autoDeclarationPart):
     *     $(LITERAL Identifier) $(RULE templateParameters)? $(LITERAL '=') $(RULE initializer)
     *     ;)
     */
    AutoDeclarationPart parseAutoDeclarationPart()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto part = allocator.make!AutoDeclarationPart;
        auto i = expect(tok!"identifier");
        if (i is null)
            return null;
        part.identifier = *i;
        if (currentIs(tok!"("))
            mixin(parseNodeQ!("part.templateParameters", "TemplateParameters"));
        mixin(tokenCheck!"=");
        mixin(parseNodeQ!("part.initializer", "Initializer"));
        return part;
    }

    /**
     * Parses a BlockStatement
     *
     * $(GRAMMAR $(RULEDEF blockStatement):
     *     $(LITERAL '{') $(RULE declarationsAndStatements)? $(LITERAL '}')
     *     ;)
     */
    BlockStatement parseBlockStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!BlockStatement;
        const openBrace = expect(tok!"{");
        mixin (nullCheck!`openBrace`);
        node.startLocation = openBrace.index;
        if (!currentIs(tok!"}"))
        {
            mixin(parseNodeQ!(`node.declarationsAndStatements`, `DeclarationsAndStatements`));
        }
        const closeBrace = expect(tok!"}");
        if (closeBrace !is null)
            node.endLocation = closeBrace.index;
        else
        {
            trace("Could not find end of block statement.");
            node.endLocation = size_t.max;
        }

        return node;
    }

    /**
     * Parses a BodyStatement
     *
     * $(GRAMMAR $(RULEDEF bodyStatement):
     *     $(LITERAL 'body') $(RULE blockStatement)
     *     ;)
     */
    BodyStatement parseBodyStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin (simpleParse!(BodyStatement, tok!"body",
            "blockStatement|parseBlockStatement"));
    }

    /**
     * Parses a BreakStatement
     *
     * $(GRAMMAR $(RULEDEF breakStatement):
     *     $(LITERAL 'break') $(LITERAL Identifier)? $(LITERAL ';')
     *     ;)
     */
    BreakStatement parseBreakStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        expect(tok!"break");
        auto node = allocator.make!BreakStatement;
        switch (current.type)
        {
        case tok!"identifier":
            node.label = advance();
            mixin(tokenCheck!";");
            break;
        case tok!";":
            advance();
            break;
        default:
            error("Identifier or semicolon expected following \"break\"");
            return null;
        }
        return node;
    }

    /**
     * Parses a BaseClass
     *
     * $(GRAMMAR $(RULEDEF baseClass):
     *     $(RULE type2)
     *     ;)
     */
    BaseClass parseBaseClass()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!BaseClass;
        if (current.type.isProtection())
        {
            warn("Use of base class protection is deprecated.");
            advance();
        }
        if ((node.type2 = parseType2()) is null)
        {
            return null;
        }
        return node;
    }

    /**
     * Parses a BaseClassList
     *
     * $(GRAMMAR $(RULEDEF baseClassList):
     *     $(RULE baseClass) ($(LITERAL ',') $(RULE baseClass))*
     *     ;)
     */
    BaseClassList parseBaseClassList()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseCommaSeparatedRule!(BaseClassList, BaseClass)();
    }

    /**
     * Parses an BuiltinType
     *
     * $(GRAMMAR $(RULEDEF builtinType):
     *      $(LITERAL 'bool')
     *    | $(LITERAL 'byte')
     *    | $(LITERAL 'ubyte')
     *    | $(LITERAL 'short')
     *    | $(LITERAL 'ushort')
     *    | $(LITERAL 'int')
     *    | $(LITERAL 'uint')
     *    | $(LITERAL 'long')
     *    | $(LITERAL 'ulong')
     *    | $(LITERAL 'char')
     *    | $(LITERAL 'wchar')
     *    | $(LITERAL 'dchar')
     *    | $(LITERAL 'float')
     *    | $(LITERAL 'double')
     *    | $(LITERAL 'real')
     *    | $(LITERAL 'ifloat')
     *    | $(LITERAL 'idouble')
     *    | $(LITERAL 'ireal')
     *    | $(LITERAL 'cfloat')
     *    | $(LITERAL 'cdouble')
     *    | $(LITERAL 'creal')
     *    | $(LITERAL 'void')
     *    ;)
     */
    IdType parseBuiltinType()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return advance().type;
    }

    /**
     * Parses a CaseRangeStatement
     *
     * $(GRAMMAR $(RULEDEF caseRangeStatement):
     *     $(LITERAL 'case') $(RULE assignExpression) $(LITERAL ':') $(LITERAL '...') $(LITERAL 'case') $(RULE assignExpression) $(LITERAL ':') $(RULE declarationsAndStatements)
     *     ;)
     */
    CaseRangeStatement parseCaseRangeStatement(ExpressionNode low)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!CaseRangeStatement;
        assert (low !is null);
        node.low = low;
        mixin(tokenCheck!":");
        mixin(tokenCheck!"..");
        expect(tok!"case");
        mixin(parseNodeQ!(`node.high`, `AssignExpression`));
        const colon = expect(tok!":");
        if (colon is null)
            return null;
        node.colonLocation = colon.index;
        mixin(parseNodeQ!(`node.declarationsAndStatements`, `DeclarationsAndStatements`));
        return node;
    }

    /**
     * Parses an CaseStatement
     *
     * $(GRAMMAR $(RULEDEF caseStatement):
     *     $(LITERAL 'case') $(RULE argumentList) $(LITERAL ':') $(RULE declarationsAndStatements)
     *     ;)
     */
    CaseStatement parseCaseStatement(ArgumentList argumentList = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!CaseStatement;
        node.argumentList = argumentList;
        const colon = expect(tok!":");
        if (colon is null)
            return null;
        node.colonLocation = colon.index;
        mixin (nullCheck!`node.declarationsAndStatements = parseDeclarationsAndStatements(false)`);
        return node;
    }

    /**
     * Parses a CastExpression
     *
     * $(GRAMMAR $(RULEDEF castExpression):
     *     $(LITERAL 'cast') $(LITERAL '$(LPAREN)') ($(RULE type) | $(RULE castQualifier))? $(LITERAL '$(RPAREN)') $(RULE unaryExpression)
     *     ;)
     */
    CastExpression parseCastExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!CastExpression;
        expect(tok!"cast");
        mixin(tokenCheck!"(");
        if (!currentIs(tok!")"))
        {
            if (isCastQualifier())
                mixin(parseNodeQ!(`node.castQualifier`, `CastQualifier`));
            else
                mixin(parseNodeQ!(`node.type`, `Type`));
        }
        mixin(tokenCheck!")");
        mixin(parseNodeQ!(`node.unaryExpression`, `UnaryExpression`));
        return node;
    }

    /**
     * Parses a CastQualifier
     *
     * $(GRAMMAR $(RULEDEF castQualifier):
     *      $(LITERAL 'const')
     *    | $(LITERAL 'const') $(LITERAL 'shared')
     *    | $(LITERAL 'immutable')
     *    | $(LITERAL 'inout')
     *    | $(LITERAL 'inout') $(LITERAL 'shared')
     *    | $(LITERAL 'shared')
     *    | $(LITERAL 'shared') $(LITERAL 'const')
     *    | $(LITERAL 'shared') $(LITERAL 'inout')
     *    ;)
     */
    CastQualifier parseCastQualifier()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!CastQualifier;
        switch (current.type)
        {
        case tok!"inout":
        case tok!"const":
            node.first = advance();
            if (currentIs(tok!"shared"))
                node.second = advance();
            break;
        case tok!"shared":
            node.first = advance();
            if (currentIsOneOf(tok!"const", tok!"inout"))
                node.second = advance();
            break;
        case tok!"immutable":
            node.first = advance();
            break;
        default:
            error("const, immutable, inout, or shared expected");
            return null;
        }
        return node;
    }

    /**
     * Parses a Catch
     *
     * $(GRAMMAR $(RULEDEF catch):
     *     $(LITERAL 'catch') $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL Identifier)? $(LITERAL '$(RPAREN)') $(RULE declarationOrStatement)
     *     ;)
     */
    Catch parseCatch()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Catch;
        expect(tok!"catch");
        mixin(tokenCheck!"(");
        mixin(parseNodeQ!(`node.type`, `Type`));
        if (currentIs(tok!"identifier"))
            node.identifier = advance();
        mixin(tokenCheck!")");
        mixin(parseNodeQ!(`node.declarationOrStatement`, `DeclarationOrStatement`));
        return node;
    }

    /**
     * Parses a Catches
     *
     * $(GRAMMAR $(RULEDEF catches):
     *       $(RULE catch)+
     *     | $(RULE catch)* $(RULE lastCatch)
     *     ;)
     */
    Catches parseCatches()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Catches;
        StackBuffer catches;
        while (moreTokens())
        {
            if (!currentIs(tok!"catch"))
                break;
            if (peekIs(tok!"("))
            {
                if (!catches.put(parseCatch()))
                    return null;
            }
            else
            {
                mixin(parseNodeQ!(`node.lastCatch`, `LastCatch`));
                break;
            }
        }
        ownArray(node.catches, catches);
        return node;
    }

    /**
     * Parses a ClassDeclaration
     *
     * $(GRAMMAR $(RULEDEF classDeclaration):
     *       $(LITERAL 'class') $(LITERAL Identifier) $(LITERAL ';')
     *     | $(LITERAL 'class') $(LITERAL Identifier) ($(LITERAL ':') $(RULE baseClassList))? $(RULE structBody)
     *     | $(LITERAL 'class') $(LITERAL Identifier) $(RULE templateParameters) $(RULE constraint)? ($(RULE structBody) | $(LITERAL ';'))
     *     | $(LITERAL 'class') $(LITERAL Identifier) $(RULE templateParameters) $(RULE constraint)? ($(LITERAL ':') $(RULE baseClassList))? $(RULE structBody)
     *     | $(LITERAL 'class') $(LITERAL Identifier) $(RULE templateParameters) ($(LITERAL ':') $(RULE baseClassList))? $(RULE constraint)? $(RULE structBody)
     *     ;)
     */
    ClassDeclaration parseClassDeclaration(Attribute[] attributes = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ClassDeclaration;
        node.attributes = attributes;
        expect(tok!"class");
        return parseInterfaceOrClass(node);
    }

    /**
     * Parses a CmpExpression
     *
     * $(GRAMMAR $(RULEDEF cmpExpression):
     *       $(RULE shiftExpression)
     *     | $(RULE equalExpression)
     *     | $(RULE identityExpression)
     *     | $(RULE relExpression)
     *     | $(RULE inExpression)
     *     ;)
     */
    ExpressionNode parseCmpExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto shift = parseShiftExpression();
        if (shift is null)
            return null;
        if (!moreTokens())
            return shift;
        switch (current.type)
        {
        case tok!"is":
            auto node = allocator.make!CmpExpression;
            mixin (nullCheck!`node.identityExpression = parseIdentityExpression(shift)`);
            return node;
        case tok!"in":
            auto node = allocator.make!CmpExpression;
            mixin (nullCheck!`node.inExpression = parseInExpression(shift)`);
            return node;
        case tok!"!":
            auto node = allocator.make!CmpExpression;
            if (peekIs(tok!"is"))
                mixin (nullCheck!`node.identityExpression = parseIdentityExpression(shift)`);
            else if (peekIs(tok!"in"))
                mixin (nullCheck!`node.inExpression = parseInExpression(shift)`);
            return node;
        case tok!"<":
        case tok!"<=":
        case tok!">":
        case tok!">=":
        case tok!"!<>=":
        case tok!"!<>":
        case tok!"<>":
        case tok!"<>=":
        case tok!"!>":
        case tok!"!>=":
        case tok!"!<":
        case tok!"!<=":
            auto node = allocator.make!CmpExpression;
            mixin (nullCheck!`node.relExpression = parseRelExpression(shift)`);
            return node;
        case tok!"==":
        case tok!"!=":
            auto node = allocator.make!CmpExpression;
            mixin (nullCheck!`node.equalExpression = parseEqualExpression(shift)`);
            return node;
        default:
            return shift;
        }
    }

    /**
     * Parses a CompileCondition
     *
     * $(GRAMMAR $(RULEDEF compileCondition):
     *       $(RULE versionCondition)
     *     | $(RULE debugCondition)
     *     | $(RULE staticIfCondition)
     *     ;)
     */
    CompileCondition parseCompileCondition()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!CompileCondition;
        switch (current.type)
        {
        case tok!"version":
            mixin(parseNodeQ!(`node.versionCondition`, `VersionCondition`));
            break;
        case tok!"debug":
            mixin(parseNodeQ!(`node.debugCondition`, `DebugCondition`));
            break;
        case tok!"static":
            mixin(parseNodeQ!(`node.staticIfCondition`, `StaticIfCondition`));
            break;
        default:
            error(`"version", "debug", or "static" expected`);
            return null;
        }
        return node;
    }

    /**
     * Parses a ConditionalDeclaration
     *
     * $(GRAMMAR $(RULEDEF conditionalDeclaration):
     *       $(RULE compileCondition) $(RULE declaration)
     *     | $(RULE compileCondition) $(LITERAL '{') $(RULE declaration)* $(LITERAL '}')
     *     | $(RULE compileCondition) $(LITERAL ':') $(RULE declaration)+
     *     | $(RULE compileCondition) $(RULE declaration) $(LITERAL 'else') $(LITERAL ':') $(RULE declaration)*
     *     | $(RULE compileCondition) $(RULE declaration) $(LITERAL 'else') $(RULE declaration)
     *     | $(RULE compileCondition) $(RULE declaration) $(LITERAL 'else') $(LITERAL '{') $(RULE declaration)* $(LITERAL '}')
     *     | $(RULE compileCondition) $(LITERAL '{') $(RULE declaration)* $(LITERAL '}') $(LITERAL 'else') $(RULE declaration)
     *     | $(RULE compileCondition) $(LITERAL '{') $(RULE declaration)* $(LITERAL '}') $(LITERAL 'else') $(LITERAL '{') $(RULE declaration)* $(LITERAL '}')
     *     | $(RULE compileCondition) $(LITERAL '{') $(RULE declaration)* $(LITERAL '}') $(LITERAL 'else') $(LITERAL ':') $(RULE declaration)*
     *     | $(RULE compileCondition) $(LITERAL ':') $(RULE declaration)+ $(LITERAL 'else') $(RULE declaration)
     *     | $(RULE compileCondition) $(LITERAL ':') $(RULE declaration)+ $(LITERAL 'else') $(LITERAL '{') $(RULE declaration)* $(LITERAL '}')
     *     | $(RULE compileCondition) $(LITERAL ':') $(RULE declaration)+ $(LITERAL 'else') $(LITERAL ':') $(RULE declaration)*
     *     ;)
     */
    ConditionalDeclaration parseConditionalDeclaration(bool strict)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ConditionalDeclaration;
        mixin(parseNodeQ!(`node.compileCondition`, `CompileCondition`));

        StackBuffer trueDeclarations;
        if (currentIs(tok!":") || currentIs(tok!"{"))
        {
            immutable bool brace = advance() == tok!"{";
            while (moreTokens() && !currentIs(tok!"}") && !currentIs(tok!"else"))
            {
                immutable b = setBookmark();
                immutable c = allocator.setCheckpoint();
                if (trueDeclarations.put(parseDeclaration(strict, true)))
                    abandonBookmark(b);
                else
                {
                    goToBookmark(b);
                    allocator.rollback(c);
                    return null;
                }
            }
            if (brace)
                mixin(tokenCheck!"}");
        }
        else if (!trueDeclarations.put(parseDeclaration(strict, true)))
            return null;

        ownArray(node.trueDeclarations, trueDeclarations);

        if (currentIs(tok!"else"))
        {
            node.hasElse = true;
            advance();
        }
        else
            return node;

        StackBuffer falseDeclarations;
        if (currentIs(tok!":") || currentIs(tok!"{"))
        {
            immutable bool brace = currentIs(tok!"{");
            advance();
            while (moreTokens() && !currentIs(tok!"}"))
                if (!falseDeclarations.put(parseDeclaration(strict, true)))
                    return null;
            if (brace)
                mixin(tokenCheck!"}");
        }
        else
        {
            if (!falseDeclarations.put(parseDeclaration(strict, true)))
                return null;
        }
        ownArray(node.falseDeclarations, falseDeclarations);
        return node;
    }

    /**
     * Parses a ConditionalStatement
     *
     * $(GRAMMAR $(RULEDEF conditionalStatement):
     *     $(RULE compileCondition) $(RULE declarationOrStatement) ($(LITERAL 'else') $(RULE declarationOrStatement))?
     *     ;)
     */
    ConditionalStatement parseConditionalStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ConditionalStatement;
        mixin(parseNodeQ!(`node.compileCondition`, `CompileCondition`));
        mixin(parseNodeQ!(`node.trueStatement`, `DeclarationOrStatement`));
        if (currentIs(tok!"else"))
        {
            advance();
            mixin(parseNodeQ!(`node.falseStatement`, `DeclarationOrStatement`));
        }
        return node;
    }

    /**
     * Parses a Constraint
     *
     * $(GRAMMAR $(RULEDEF constraint):
     *     $(LITERAL 'if') $(LITERAL '$(LPAREN)') $(RULE expression) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    Constraint parseConstraint()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Constraint;
        auto ifToken = expect(tok!"if");
        mixin (nullCheck!`ifToken`);
        node.location = ifToken.index;
        mixin(tokenCheck!"(");
        mixin(parseNodeQ!(`node.expression`, `Expression`));
        mixin(tokenCheck!")");
        return node;
    }

    /**
     * Parses a Constructor
     *
     * $(GRAMMAR $(RULEDEF constructor):
     *       $(LITERAL 'this') $(RULE templateParameters)? $(RULE parameters) $(RULE memberFunctionAttribute)* $(RULE constraint)? ($(RULE functionBody) | $(LITERAL ';'))
     *     ;)
     */
    Constructor parseConstructor()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        Constructor node = allocator.make!Constructor;
        node.comment = comment;
        comment = null;
        const t = expect(tok!"this");
        mixin (nullCheck!`t`);
        node.location = t.index;
        node.line = t.line;
        node.column = t.column;
        const p = peekPastParens();
        bool isTemplate = false;
        if (p !is null && p.type == tok!"(")
        {
            isTemplate = true;
            mixin(parseNodeQ!(`node.templateParameters`, `TemplateParameters`));
        }
        mixin(parseNodeQ!(`node.parameters`, `Parameters`));

        StackBuffer memberFunctionAttributes;
        while (moreTokens() && currentIsMemberFunctionAttribute())
            if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                return null;
        ownArray(node.memberFunctionAttributes, memberFunctionAttributes);

        if (isTemplate && currentIs(tok!"if"))
            mixin(parseNodeQ!(`node.constraint`, `Constraint`));
        if (currentIs(tok!";"))
            advance();
        else
            mixin(parseNodeQ!(`node.functionBody`, `FunctionBody`));
        return node;
    }

    /**
     * Parses an ContinueStatement
     *
     * $(GRAMMAR $(RULEDEF continueStatement):
     *     $(LITERAL 'continue') $(LITERAL Identifier)? $(LITERAL ';')
     *     ;)
     */
    ContinueStatement parseContinueStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ContinueStatement;
        mixin(tokenCheck!"continue");
        switch (current.type)
        {
        case tok!"identifier":
            node.label = advance();
            mixin(tokenCheck!";");
            break;
        case tok!";":
            advance();
            break;
        default:
            error(`Identifier or semicolon expected following "continue"`);
            return null;
        }
        return node;
    }

    /**
     * Parses a DebugCondition
     *
     * $(GRAMMAR $(RULEDEF debugCondition):
     *     $(LITERAL 'debug') ($(LITERAL '$(LPAREN)') ($(LITERAL IntegerLiteral) | $(LITERAL Identifier)) $(LITERAL '$(RPAREN)'))?
     *     ;)
     */
    DebugCondition parseDebugCondition()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!DebugCondition;

        const d = expect(tok!"debug");
        mixin (nullCheck!`d`);
        node.debugIndex = d.index;

        if (currentIs(tok!"("))
        {
            advance();
            if (currentIsOneOf(tok!"intLiteral", tok!"identifier"))
                node.identifierOrInteger = advance();
            else
            {
                error(`Integer literal or identifier expected`);
                return null;
            }
            mixin(tokenCheck!")");
        }
        return node;
    }

    /**
     * Parses a DebugSpecification
     *
     * $(GRAMMAR $(RULEDEF debugSpecification):
     *     $(LITERAL 'debug') $(LITERAL '=') ($(LITERAL Identifier) | $(LITERAL IntegerLiteral)) $(LITERAL ';')
     *     ;)
     */
    DebugSpecification parseDebugSpecification()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!DebugSpecification;
        mixin(tokenCheck!"debug");
        mixin(tokenCheck!"=");
        if (currentIsOneOf(tok!"identifier", tok!"intLiteral"))
            node.identifierOrInteger = advance();
        else
        {
            error("Integer literal or identifier expected");
            return null;
        }
        mixin(tokenCheck!";");
        return node;
    }

    /**
     * Parses a Declaration
     *
     * Params: strict = if true, do not return partial AST nodes on errors.
     *
     * $(GRAMMAR $(RULEDEF declaration):
     *       $(RULE attribute)* $(RULE declaration2)
     *     | $(RULE attribute)+ $(LITERAL '{') $(RULE declaration)* $(LITERAL '}')
     *     ;
     * $(RULEDEF declaration2):
     *       $(RULE aliasDeclaration)
     *     | $(RULE aliasThisDeclaration)
     *     | $(RULE anonymousEnumDeclaration)
     *     | $(RULE attributeDeclaration)
     *     | $(RULE classDeclaration)
     *     | $(RULE conditionalDeclaration)
     *     | $(RULE constructor)
     *     | $(RULE debugSpecification)
     *     | $(RULE destructor)
     *     | $(RULE enumDeclaration)
     *     | $(RULE eponymousTemplateDeclaration)
     *     | $(RULE functionDeclaration)
     *     | $(RULE importDeclaration)
     *     | $(RULE interfaceDeclaration)
     *     | $(RULE invariant)
     *     | $(RULE mixinDeclaration)
     *     | $(RULE mixinTemplateDeclaration)
     *     | $(RULE pragmaDeclaration)
     *     | $(RULE sharedStaticConstructor)
     *     | $(RULE sharedStaticDestructor)
     *     | $(RULE staticAssertDeclaration)
     *     | $(RULE staticConstructor)
     *     | $(RULE staticDestructor)
     *     | $(RULE structDeclaration)
     *     | $(RULE templateDeclaration)
     *     | $(RULE unionDeclaration)
     *     | $(RULE unittest)
     *     | $(RULE variableDeclaration)
     *     | $(RULE versionSpecification)
     *     ;)
     */
    Declaration parseDeclaration(bool strict = false, bool mustBeDeclaration = false)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Declaration;
        if (!moreTokens)
        {
            error("declaration expected instead of EOF");
            return null;
        }
        if (current.comment !is null)
            comment = current.comment;
        size_t autoStorageClassStart = size_t.max;
        DecType isAuto;
        StackBuffer attributes;
        do
        {
            isAuto = isAutoDeclaration(autoStorageClassStart);
            if (isAuto != DecType.other && index == autoStorageClassStart)
                break;
            if (!isAttribute())
                break;
            immutable c = allocator.setCheckpoint();
            auto attr = parseAttribute();
            if (attr is null)
            {
                allocator.rollback(c);
                break;
            }
            if (currentIs(tok!":"))
            {
                node.attributeDeclaration = parseAttributeDeclaration(attr);
                mixin(nullCheck!`node.attributeDeclaration`);
                ownArray(node.attributes, attributes);
                return node;
            }
            else
                attributes.put(attr);
        } while (moreTokens());
        ownArray(node.attributes, attributes);

        if (!moreTokens)
        {
            error("declaration expected instead of EOF");
            return null;
        }

        if (isAuto == DecType.autoVar)
        {
            mixin(nullCheck!`node.variableDeclaration = parseVariableDeclaration(null, true)`);
            return node;
        }
        else if (isAuto == DecType.autoFun)
        {
            mixin(nullCheck!`node.functionDeclaration = parseFunctionDeclaration(null, true)`);
            return node;
        }

        switch (current.type)
        {
        case tok!"asm":
        case tok!"break":
        case tok!"case":
        case tok!"continue":
        case tok!"default":
        case tok!"do":
        case tok!"for":
        case tok!"foreach":
        case tok!"foreach_reverse":
        case tok!"goto":
        case tok!"if":
        case tok!"return":
        case tok!"switch":
        case tok!"throw":
        case tok!"try":
        case tok!"while":
        case tok!"assert":
            goto default;
        case tok!";":
            // http://d.puremagic.com/issues/show_bug.cgi?id=4559
            warn("Empty declaration");
            advance();
            break;
        case tok!"{":
            if (node.attributes.empty)
            {
                error("declaration expected instead of '{'");
                return null;
            }
            advance();
            StackBuffer declarations;
            while (moreTokens() && !currentIs(tok!"}"))
            {
                auto c = allocator.setCheckpoint();
                if (!declarations.put(parseDeclaration(strict)))
                {
                    allocator.rollback(c);
                    return null;
                }
            }
            ownArray(node.declarations, declarations);
            mixin(tokenCheck!"}");
            break;
        case tok!"alias":
            if (startsWith(tok!"alias", tok!"identifier", tok!"this"))
                mixin(parseNodeQ!(`node.aliasThisDeclaration`, `AliasThisDeclaration`));
            else
                mixin(parseNodeQ!(`node.aliasDeclaration`, `AliasDeclaration`));
            break;
        case tok!"class":
            if((node.classDeclaration = parseClassDeclaration(node.attributes)) is null) return null;
            break;
        case tok!"this":
            if (!mustBeDeclaration && peekIs(tok!"("))
            {
                // Do not parse as a declaration if we could parse as a function call.
                ++index;
                const past = peekPastParens();
                --index;
                if (past !is null && past.type == tok!";")
                    return null;
            }
            if (startsWith(tok!"this", tok!"(", tok!"this", tok!")"))
                mixin(parseNodeQ!(`node.postblit`, `Postblit`));
            else
                mixin(parseNodeQ!(`node.constructor`, `Constructor`));
            break;
        case tok!"~":
            mixin(parseNodeQ!(`node.destructor`, `Destructor`));
            break;
        case tok!"enum":
            immutable b = setBookmark();
            advance(); // enum
            if (currentIsOneOf(tok!":", tok!"{"))
            {
                goToBookmark(b);
                mixin(parseNodeQ!(`node.anonymousEnumDeclaration`, `AnonymousEnumDeclaration`));
            }
            else if (currentIs(tok!"identifier"))
            {
                advance();
                if (currentIs(tok!"("))
                {
                    skipParens(); // ()
                    if (currentIs(tok!"("))
                        skipParens();
                    if (!currentIs(tok!"="))
                    {
                        goToBookmark(b);
                        node.functionDeclaration = parseFunctionDeclaration(null, true, node.attributes);
                        mixin (nullCheck!`node.functionDeclaration`);
                    }
                    else
                    {
                        goToBookmark(b);
                        mixin(parseNodeQ!(`node.eponymousTemplateDeclaration`, `EponymousTemplateDeclaration`));
                    }
                }
                else if (currentIsOneOf(tok!":", tok!"{", tok!";"))
                {
                    goToBookmark(b);
                    mixin(parseNodeQ!(`node.enumDeclaration`, `EnumDeclaration`));
                }
                else
                {
                    immutable bool eq = currentIs(tok!"=");
                    goToBookmark(b);
                    mixin (nullCheck!`node.variableDeclaration = parseVariableDeclaration(null, eq)`);
                }
            }
            else
            {
                immutable bool s = isStorageClass();
                goToBookmark(b);
                mixin (nullCheck!`node.variableDeclaration = parseVariableDeclaration(null, s)`);
            }
            break;
        case tok!"import":
            mixin(parseNodeQ!(`node.importDeclaration`, `ImportDeclaration`));
            break;
        case tok!"interface":
            mixin(parseNodeQ!(`node.interfaceDeclaration`, `InterfaceDeclaration`));
            break;
        case tok!"mixin":
            if (peekIs(tok!"template"))
                mixin(parseNodeQ!(`node.mixinTemplateDeclaration`, `MixinTemplateDeclaration`));
            else
            {
                immutable b = setBookmark();
                advance();
                if (currentIs(tok!"("))
                {
                    const t = peekPastParens();
                    if (t !is null && t.type == tok!";")
                    {
                        goToBookmark(b);
                        mixin(parseNodeQ!(`node.mixinDeclaration`, `MixinDeclaration`));
                    }
                    else
                    {
                        goToBookmark(b);
                        error("Declaration expected");
                        return null;
                    }
                }
                else
                {
                    goToBookmark(b);
                    mixin(parseNodeQ!(`node.mixinDeclaration`, `MixinDeclaration`));
                }
            }
            break;
        case tok!"pragma":
            mixin(parseNodeQ!(`node.pragmaDeclaration`, `PragmaDeclaration`));
            break;
        case tok!"shared":
            if (startsWith(tok!"shared", tok!"static", tok!"this"))
                mixin(parseNodeQ!(`node.sharedStaticConstructor`, `SharedStaticConstructor`));
            else if (startsWith(tok!"shared", tok!"static", tok!"~"))
                mixin(parseNodeQ!(`node.sharedStaticDestructor`, `SharedStaticDestructor`));
            else
                goto type;
            break;
        case tok!"static":
            if (peekIs(tok!"this"))
                mixin(parseNodeQ!(`node.staticConstructor`, `StaticConstructor`));
            else if (peekIs(tok!"~"))
                mixin(parseNodeQ!(`node.staticDestructor`, `StaticDestructor`));
            else if (peekIs(tok!"if"))
                mixin (nullCheck!`node.conditionalDeclaration = parseConditionalDeclaration(strict)`);
            else if (peekIs(tok!"assert"))
                mixin(parseNodeQ!(`node.staticAssertDeclaration`, `StaticAssertDeclaration`));
            else
                goto type;
            break;
        case tok!"struct":
            if((node.structDeclaration = parseStructDeclaration(node.attributes)) is null) return null;
            break;
        case tok!"template":
            mixin(parseNodeQ!(`node.templateDeclaration`, `TemplateDeclaration`));
            break;
        case tok!"union":
            mixin(parseNodeQ!(`node.unionDeclaration`, `UnionDeclaration`));
            break;
        case tok!"invariant":
            mixin(parseNodeQ!(`node.invariant_`, `Invariant`));
            break;
        case tok!"unittest":
            mixin(parseNodeQ!(`node.unittest_`, `Unittest`));
            break;
        case tok!"identifier":
        case tok!".":
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"scope":
        case tok!"typeof":
        case tok!"__vector":
		foreach (B; BasicTypes) { case B: }
        type:
            Type t = parseType();
            if (t is null || !currentIs(tok!"identifier"))
                return null;
            if (peekIs(tok!"("))
                mixin (nullCheck!`node.functionDeclaration = parseFunctionDeclaration(t, false)`);
            else
                mixin (nullCheck!`node.variableDeclaration = parseVariableDeclaration(t, false)`);
            break;
        case tok!"version":
            if (peekIs(tok!"("))
                mixin (nullCheck!`node.conditionalDeclaration = parseConditionalDeclaration(strict)`);
            else if (peekIs(tok!"="))
                mixin(parseNodeQ!(`node.versionSpecification`, `VersionSpecification`));
            else
            {
                error(`"=" or "(" expected following "version"`);
                return null;
            }
            break;
        case tok!"debug":
            if (peekIs(tok!"="))
                mixin(parseNodeQ!(`node.debugSpecification`, `DebugSpecification`));
            else
                mixin (nullCheck!`node.conditionalDeclaration = parseConditionalDeclaration(strict)`);
            break;
        default:
            error("Declaration expected");
            return null;
        }
        return node;
    }

    /**
     * Parses DeclarationsAndStatements
     *
     * $(GRAMMAR $(RULEDEF declarationsAndStatements):
     *     $(RULE declarationOrStatement)+
     *     ;)
     */
    DeclarationsAndStatements parseDeclarationsAndStatements(bool includeCases = true)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!DeclarationsAndStatements;
        StackBuffer declarationsAndStatements;
        while (!currentIsOneOf(tok!"}", tok!"else") && moreTokens() && suppressedErrorCount <= MAX_ERRORS)
        {
            if (currentIs(tok!"case") && !includeCases)
                break;
            if (currentIs(tok!"while"))
            {
                immutable b = setBookmark();
                scope (exit) goToBookmark(b);
                advance();
                if (currentIs(tok!"("))
                {
                    const p = peekPastParens();
                    if (p !is null && *p == tok!";")
                        break;
                }
            }
            immutable c = allocator.setCheckpoint();
            if (!declarationsAndStatements.put(parseDeclarationOrStatement()))
            {
                allocator.rollback(c);
                if (suppressMessages > 0)
                    return null;
            }
        }
        ownArray(node.declarationsAndStatements, declarationsAndStatements);
        return node;
    }

    /**
     * Parses a DeclarationOrStatement
     *
     * $(GRAMMAR $(RULEDEF declarationOrStatement):
     *       $(RULE declaration)
     *     | $(RULE statement)
     *     ;)
     */
    DeclarationOrStatement parseDeclarationOrStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!DeclarationOrStatement;
        // "Any ambiguities in the grammar between Statements and
        // Declarations are resolved by the declarations taking precedence."
        immutable b = setBookmark();
        immutable c = allocator.setCheckpoint();
        auto d = parseDeclaration(true, false);
        if (d is null)
        {
            allocator.rollback(c);
            goToBookmark(b);
            mixin(parseNodeQ!(`node.statement`, `Statement`));
        }
        else
        {
            // TODO: Make this more efficient. Right now we parse the declaration
            // twice, once with errors and warnings ignored, and once with them
            // printed. Maybe store messages to then be abandoned or written later?
            allocator.rollback(c);
            goToBookmark(b);
            node.declaration = parseDeclaration(true, true);
        }
        return node;
    }

    /**
     * Parses a Declarator
     *
     * $(GRAMMAR $(RULEDEF declarator):
     *       $(LITERAL Identifier)
     *     | $(LITERAL Identifier) $(LITERAL '=') $(RULE initializer)
     *     | $(LITERAL Identifier) $(RULE templateParameters) $(LITERAL '=') $(RULE initializer)
     *     ;)
     */
    Declarator parseDeclarator()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Declarator;
        const id = expect(tok!"identifier");
        mixin (nullCheck!`id`);
        node.name = *id;
        if (currentIs(tok!"[")) // dmd doesn't accept pointer after identifier
        {
            warn("C-style array declaration.");
            StackBuffer typeSuffixes;
            while (moreTokens() && currentIs(tok!"["))
                if (!typeSuffixes.put(parseTypeSuffix()))
                    return null;
            ownArray(node.cstyle, typeSuffixes);
        }
        if (currentIs(tok!"("))
        {
            mixin (nullCheck!`(node.templateParameters = parseTemplateParameters())`);
            mixin(tokenCheck!"=");
            mixin (nullCheck!`(node.initializer = parseInitializer())`);
        }
        else if (currentIs(tok!"="))
        {
            advance();
            mixin(parseNodeQ!(`node.initializer`, `Initializer`));
        }
        return node;
    }

    /**
     * Parses a DefaultStatement
     *
     * $(GRAMMAR $(RULEDEF defaultStatement):
     *     $(LITERAL 'default') $(LITERAL ':') $(RULE declarationsAndStatements)
     *     ;)
     */
    DefaultStatement parseDefaultStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!DefaultStatement;
        mixin(tokenCheck!"default");
        const colon = expect(tok!":");
        if (colon is null)
            return null;
        node.colonLocation = colon.index;
        mixin(parseNodeQ!(`node.declarationsAndStatements`, `DeclarationsAndStatements`));
        return node;
    }

    /**
     * Parses a DeleteExpression
     *
     * $(GRAMMAR $(RULEDEF deleteExpression):
     *     $(LITERAL 'delete') $(RULE unaryExpression)
     *     ;)
     */
    DeleteExpression parseDeleteExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!DeleteExpression;
        node.line = current.line;
        node.column = current.column;
        mixin(tokenCheck!"delete");
        mixin(parseNodeQ!(`node.unaryExpression`, `UnaryExpression`));
        return node;
    }

    /**
     * Parses a Deprecated attribute
     *
     * $(GRAMMAR $(RULEDEF deprecated):
     *     $(LITERAL 'deprecated') ($(LITERAL '$(LPAREN)') $(LITERAL StringLiteral)+ $(LITERAL '$(RPAREN)'))?
     *     ;)
     */
    Deprecated parseDeprecated()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Deprecated;
        mixin(tokenCheck!"deprecated");
        if (currentIs(tok!"("))
        {
            advance();
            mixin (parseNodeQ!(`node.assignExpression`, `AssignExpression`));
            mixin (tokenCheck!")");
        }
        return node;
    }

    /**
     * Parses a Destructor
     *
     * $(GRAMMAR $(RULEDEF destructor):
     *     $(LITERAL '~') $(LITERAL 'this') $(LITERAL '$(LPAREN)') $(LITERAL '$(RPAREN)') $(RULE memberFunctionAttribute)* ($(RULE functionBody) | $(LITERAL ';'))
     *     ;)
     */
    Destructor parseDestructor()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Destructor;
        node.comment = comment;
        comment = null;
        mixin(tokenCheck!"~");
        if (!moreTokens)
        {
            error("'this' expected");
            return null;
        }
        node.index = current.index;
        node.line = current.line;
        node.column = current.column;
        mixin(tokenCheck!"this");
        mixin(tokenCheck!"(");
        mixin(tokenCheck!")");
        if (currentIs(tok!";"))
            advance();
        else
        {
            StackBuffer memberFunctionAttributes;
            while (moreTokens() && currentIsMemberFunctionAttribute())
                if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                    return null;
            ownArray(node.memberFunctionAttributes, memberFunctionAttributes);
            mixin(parseNodeQ!(`node.functionBody`, `FunctionBody`));
        }
        return node;
    }

    /**
     * Parses a DoStatement
     *
     * $(GRAMMAR $(RULEDEF doStatement):
     *     $(LITERAL 'do') $(RULE statementNoCaseNoDefault) $(LITERAL 'while') $(LITERAL '$(LPAREN)') $(RULE expression) $(LITERAL '$(RPAREN)') $(LITERAL ';')
     *     ;)
     */
    DoStatement parseDoStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!DoStatement;
        mixin(tokenCheck!"do");
        mixin(parseNodeQ!(`node.statementNoCaseNoDefault`, `StatementNoCaseNoDefault`));
        mixin(tokenCheck!"while");
        mixin(tokenCheck!"(");
        mixin(parseNodeQ!(`node.expression`, `Expression`));
        mixin(tokenCheck!")");
        mixin(tokenCheck!";");
        return node;
    }

    /**
     * Parses an EnumBody
     *
     * $(GRAMMAR $(RULEDEF enumBody):
     *     $(LITERAL '{') $(RULE enumMember) ($(LITERAL ',') $(RULE enumMember)?)* $(LITERAL '}')
     *     ;)
     */
    EnumBody parseEnumBody()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        EnumBody node = allocator.make!EnumBody;
        const open = expect(tok!"{");
        mixin (nullCheck!`open`);
        node.startLocation = open.index;
        StackBuffer enumMembers;
        EnumMember last;
        while (moreTokens())
        {
            if (currentIs(tok!"identifier"))
            {
                auto c = allocator.setCheckpoint();
                auto e = parseEnumMember();
                if (!enumMembers.put(e))
                    allocator.rollback(c);
                else
                    last = e;
                if (currentIs(tok!","))
                {
                    if (last !is null && last.comment is null)
                        last.comment = current.trailingComment;
                    advance();
                    if (!currentIs(tok!"}"))
                        continue;
                }
                if (currentIs(tok!"}"))
                {
                    if (last !is null && last.comment is null)
                        last.comment = tokens[index - 1].trailingComment;
                    break;
                }
                else
                {
                    error("',' or '}' expected");
                    if (currentIs(tok!"}"))
                        break;
                }
            }
            else
                error("Enum member expected");
        }
        ownArray(node.enumMembers, enumMembers);
        const close = expect (tok!"}");
        if (close !is null)
            node.endLocation = close.index;
        return node;
    }

    /**
     * $(GRAMMAR $(RULEDEF anonymousEnumMember):
     *       $(RULE type) $(LITERAL identifier) $(LITERAL '=') $(RULE assignExpression)
     *     | $(LITERAL identifier) $(LITERAL '=') $(RULE assignExpression)
     *     | $(LITERAL identifier)
     *     ;)
     */
    AnonymousEnumMember parseAnonymousEnumMember(bool typeAllowed)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AnonymousEnumMember;

        if (currentIs(tok!"identifier") && peekIsOneOf(tok!",", tok!"=", tok!"}"))
        {
            node.comment = current.comment;
            mixin(tokenCheck!(`node.name`, `identifier`));
            if (currentIs(tok!"="))
            {
                advance(); // =
                goto assign;
            }
        }
        else if (typeAllowed)
        {
            node.comment = current.comment;
            mixin(parseNodeQ!(`node.type`, `Type`));
            mixin(tokenCheck!(`node.name`, `identifier`));
            mixin(tokenCheck!"=");
    assign:
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        }
        else
        {
            error("Cannot specify anonymous enum member type if anonymous enum has a base type.");
            return null;
        }
        return node;
    }

    /**
     * $(GRAMMAR $(RULEDEF anonymousEnumDeclaration):
     *     $(LITERAL 'enum') ($(LITERAL ':') $(RULE type))? $(LITERAL '{') $(RULE anonymousEnumMember)+ $(LITERAL '}')
     *     ;)
     */
    AnonymousEnumDeclaration parseAnonymousEnumDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!AnonymousEnumDeclaration;
        mixin(tokenCheck!"enum");
        immutable bool hasBaseType = currentIs(tok!":");
        if (hasBaseType)
        {
            advance();
            mixin(parseNodeQ!(`node.baseType`, `Type`));
        }
        mixin(tokenCheck!"{");
        StackBuffer members;
        AnonymousEnumMember last;
        while (moreTokens())
        {
            if (currentIs(tok!","))
            {
                if (last !is null && last.comment is null)
                    last.comment = current.trailingComment;
                advance();
                continue;
            }
            else if (currentIs(tok!"}"))
            {
                if (last !is null && last.comment is null)
                    last.comment = tokens[index - 1].trailingComment;
                break;
            }
            else
            {
                immutable c = allocator.setCheckpoint();
                auto e = parseAnonymousEnumMember(!hasBaseType);
                if (!members.put(e))
                    allocator.rollback(c);
                else
                    last = e;
            }
        }
        ownArray(node.members, members);
        mixin(tokenCheck!"}");
        return node;
    }

    /**
     * Parses an EnumDeclaration
     *
     * $(GRAMMAR $(RULEDEF enumDeclaration):
     *       $(LITERAL 'enum') $(LITERAL Identifier) ($(LITERAL ':') $(RULE type))? $(LITERAL ';')
     *     | $(LITERAL 'enum') $(LITERAL Identifier) ($(LITERAL ':') $(RULE type))? $(RULE enumBody)
     *     ;)
     */
    EnumDeclaration parseEnumDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!EnumDeclaration;
        mixin(tokenCheck!"enum");
        mixin (tokenCheck!(`node.name`, `identifier`));
        node.comment = comment;
        comment = null;
        if (currentIs(tok!";"))
        {
            advance();
            return node;
        }
        if (currentIs(tok!":"))
        {
            advance(); // skip ':'
            mixin(parseNodeQ!(`node.type`, `Type`));
        }
        mixin(parseNodeQ!(`node.enumBody`, `EnumBody`));
        return node;
    }

    /**
     * Parses an EnumMember
     *
     * $(GRAMMAR $(RULEDEF enumMember):
     *       $(LITERAL Identifier)
     *     | $(LITERAL Identifier) $(LITERAL '=') $(RULE assignExpression)
     *     ;)
     */
    EnumMember parseEnumMember()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!EnumMember;
        node.comment = current.comment;
        mixin (tokenCheck!(`node.name`, `identifier`));
        if (currentIs(tok!"="))
        {
            advance();
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        }
        return node;
    }

    /**
     * Parses an EponymousTemplateDeclaration
     *
     * $(GRAMMAR $(RULEDEF eponymousTemplateDeclaration):
     *     $(LITERAL 'enum') $(LITERAL Identifier) $(RULE templateParameters) $(LITERAL '=') $(RULE assignExpression) $(LITERAL ';')
     *     ;)
     */
    EponymousTemplateDeclaration parseEponymousTemplateDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!EponymousTemplateDeclaration;
        advance(); // enum
        const ident = expect(tok!"identifier");
        mixin (nullCheck!`ident`);
        node.name = *ident;
        mixin(parseNodeQ!(`node.templateParameters`, `TemplateParameters`));
        expect(tok!"=");
        node.assignExpression = parseAssignExpression();
        if (node.assignExpression is null)
            mixin(parseNodeQ!(`node.type`, `Type`));
        expect(tok!";");
        return node;
    }

    /**
     * Parses an EqualExpression
     *
     * $(GRAMMAR $(RULEDEF equalExpression):
     *     $(RULE shiftExpression) ($(LITERAL '==') | $(LITERAL '!=')) $(RULE shiftExpression)
     *     ;)
     */
    EqualExpression parseEqualExpression(ExpressionNode shift = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!EqualExpression;
        node.left = shift is null ? parseShiftExpression() : shift;
        mixin (nullCheck!`node.left`);
        if (currentIsOneOf(tok!"==", tok!"!="))
            node.operator = advance().type;
        mixin(parseNodeQ!(`node.right`, `ShiftExpression`));
        return node;
    }

    /**
     * Parses an Expression
     *
     * $(GRAMMAR $(RULEDEF expression):
     *     $(RULE assignExpression) ($(LITERAL ',') $(RULE assignExpression))*
     *     ;)
     */
    Expression parseExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (suppressedErrorCount > MAX_ERRORS)
            return null;
        if (!moreTokens())
        {
            error("Expected expression instead of EOF");
            return null;
        }
        return parseCommaSeparatedRule!(Expression, AssignExpression, true)();
    }

    /**
     * Parses an ExpressionStatement
     *
     * $(GRAMMAR $(RULEDEF expressionStatement):
     *     $(RULE expression) $(LITERAL ';')
     *     ;)
     */
    ExpressionStatement parseExpressionStatement(Expression expression = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ExpressionStatement;
        node.expression = expression is null ? parseExpression() : expression;
        if (node.expression is null || expect(tok!";") is null)
            return null;
        return node;
    }

    /**
     * Parses a FinalSwitchStatement
     *
     * $(GRAMMAR $(RULEDEF finalSwitchStatement):
     *     $(LITERAL 'final') $(RULE switchStatement)
     *     ;)
     */
    FinalSwitchStatement parseFinalSwitchStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin (simpleParse!(FinalSwitchStatement, tok!"final", "switchStatement|parseSwitchStatement"));
    }

    /**
     * Parses a Finally
     *
     * $(GRAMMAR $(RULEDEF finally):
     *     $(LITERAL 'finally') $(RULE declarationOrStatement)
     *     ;)
     */
    Finally parseFinally()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Finally;
        mixin(tokenCheck!"finally");
        mixin(parseNodeQ!(`node.declarationOrStatement`, `DeclarationOrStatement`));
        return node;
    }

    /**
     * Parses a ForStatement
     *
     * $(GRAMMAR $(RULEDEF forStatement):
     *     $(LITERAL 'for') $(LITERAL '$(LPAREN)') ($(RULE declaration) | $(RULE statementNoCaseNoDefault)) $(RULE expression)? $(LITERAL ';') $(RULE expression)? $(LITERAL '$(RPAREN)') $(RULE declarationOrStatement)
     *     ;)
     */
    ForStatement parseForStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ForStatement;
        mixin(tokenCheck!"for");
        if (!moreTokens) node.startIndex = current().index;
        mixin(tokenCheck!"(");

        if (currentIs(tok!";"))
            advance();
        else
            mixin(parseNodeQ!(`node.initialization`, `DeclarationOrStatement`));

        if (currentIs(tok!";"))
            advance();
        else
        {
            mixin(parseNodeQ!(`node.test`, `Expression`));
            expect(tok!";");
        }

        if (!currentIs(tok!")"))
             mixin(parseNodeQ!(`node.increment`, `Expression`));

        mixin(tokenCheck!")");

        // Intentionally return an incomplete parse tree so that DCD will work
        // more correctly.
        if (currentIs(tok!"}"))
        {
            error("Statement expected", false);
            return node;
        }

        mixin(parseNodeQ!(`node.declarationOrStatement`, `DeclarationOrStatement`));
        return node;
    }

    /**
     * Parses a ForeachStatement
     *
     * $(GRAMMAR $(RULEDEF foreachStatement):
     *       ($(LITERAL 'foreach') | $(LITERAL 'foreach_reverse')) $(LITERAL '$(LPAREN)') $(RULE foreachTypeList) $(LITERAL ';') $(RULE expression) $(LITERAL '$(RPAREN)') $(RULE declarationOrStatement)
     *     | ($(LITERAL 'foreach') | $(LITERAL 'foreach_reverse')) $(LITERAL '$(LPAREN)') $(RULE foreachType) $(LITERAL ';') $(RULE expression) $(LITERAL '..') $(RULE expression) $(LITERAL '$(RPAREN)') $(RULE declarationOrStatement)
     *     ;)
     */
    ForeachStatement parseForeachStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        ForeachStatement node = allocator.make!ForeachStatement;
        if (currentIsOneOf(tok!"foreach", tok!"foreach_reverse"))
            node.type = advance().type;
        else
        {
            error(`"foreach" or "foreach_reverse" expected`);
            return null;
        }
        node.startIndex = current().index;
        mixin(tokenCheck!"(");
        ForeachTypeList feType = parseForeachTypeList();
        mixin (nullCheck!`feType`);
        immutable bool canBeRange = feType.items.length == 1;

        mixin(tokenCheck!";");
        mixin(parseNodeQ!(`node.low`, `Expression`));
        mixin (nullCheck!`node.low`);
        if (currentIs(tok!".."))
        {
            if (!canBeRange)
            {
                error(`Cannot have more than one foreach variable for a foreach range statement`);
                return null;
            }
            advance();
            mixin(parseNodeQ!(`node.high`, `Expression`));
            node.foreachType = feType.items[0];
            mixin (nullCheck!`node.high`);
        }
        else
        {
            node.foreachTypeList = feType;
        }
        mixin(tokenCheck!")");
        if (currentIs(tok!"}"))
        {
            error("Statement expected", false);
            return node; // this line makes DCD better
        }
        mixin(parseNodeQ!(`node.declarationOrStatement`, `DeclarationOrStatement`));
        return node;
    }

    /**
     * Parses a ForeachType
     *
     * $(GRAMMAR $(RULEDEF foreachType):
     *       $(LITERAL 'ref')? $(RULE typeConstructors)? $(RULE type)? $(LITERAL Identifier)
     *     | $(RULE typeConstructors)? $(LITERAL 'ref')? $(RULE type)? $(LITERAL Identifier)
     *     ;)
     */
    ForeachType parseForeachType()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ForeachType;
        if (currentIs(tok!"ref"))
        {
            node.isRef = true;
            advance();
        }
        if (currentIsOneOf(tok!"const", tok!"immutable",
            tok!"inout", tok!"shared") && !peekIs(tok!"("))
        {
            trace("\033[01;36mType constructor");
            mixin(parseNodeQ!(`node.typeConstructors`, `TypeConstructors`));
        }
        if (currentIs(tok!"ref"))
        {
            node.isRef = true;
            advance();
        }
        if (currentIs(tok!"identifier") && peekIsOneOf(tok!",", tok!";"))
        {
            node.identifier = advance();
            return node;
        }
        mixin(parseNodeQ!(`node.type`, `Type`));
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.identifier = *ident;
        return node;
    }

    /**
     * Parses a ForeachTypeList
     *
     * $(GRAMMAR $(RULEDEF foreachTypeList):
     *     $(RULE foreachType) ($(LITERAL ',') $(RULE foreachType))*
     *     ;)
     */
    ForeachTypeList parseForeachTypeList()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseCommaSeparatedRule!(ForeachTypeList, ForeachType)();
    }

    /**
     * Parses a FunctionAttribute
     *
     * $(GRAMMAR $(RULEDEF functionAttribute):
     *       $(RULE atAttribute)
     *     | $(LITERAL 'pure')
     *     | $(LITERAL 'nothrow')
     *     ;)
     */
    FunctionAttribute parseFunctionAttribute(bool validate = true)
    {
        auto node = allocator.make!FunctionAttribute;
        switch (current.type)
        {
        case tok!"@":
            mixin(parseNodeQ!(`node.atAttribute`, `AtAttribute`));
            break;
        case tok!"pure":
        case tok!"nothrow":
            node.token = advance();
            break;
        default:
            if (validate)
                error(`@attribute, "pure", or "nothrow" expected`);
            return null;
        }
        return node;
    }

    /**
     * Parses a FunctionBody
     *
     * $(GRAMMAR $(RULEDEF functionBody):
     *       $(RULE blockStatement)
     *     | ($(RULE inStatement) | $(RULE outStatement) | $(RULE outStatement) $(RULE inStatement) | $(RULE inStatement) $(RULE outStatement))? $(RULE bodyStatement)?
     *     ;)
     */
    FunctionBody parseFunctionBody()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!FunctionBody;
        if (currentIs(tok!";"))
        {
            advance();
            return node;
        }
        else if (currentIs(tok!"{"))
            mixin(parseNodeQ!(`node.blockStatement`, `BlockStatement`));
        else if (currentIsOneOf(tok!"in", tok!"out", tok!"body"))
        {
            if (currentIs(tok!"in"))
            {
                mixin(parseNodeQ!(`node.inStatement`, `InStatement`));
                if (currentIs(tok!"out"))
                    mixin(parseNodeQ!(`node.outStatement`, `OutStatement`));
            }
            else if (currentIs(tok!"out"))
            {
                mixin(parseNodeQ!(`node.outStatement`, `OutStatement`));
                if (currentIs(tok!"in"))
                    mixin(parseNodeQ!(`node.inStatement`, `InStatement`));
            }
            // Allow function bodies without body statements because this is
            // valid inside of interfaces.
            if (currentIs(tok!"body"))
                mixin(parseNodeQ!(`node.bodyStatement`, `BodyStatement`));
        }
        else
        {
            error("'in', 'out', 'body', or block statement expected");
            return null;
        }
        return node;
    }

    /**
     * Parses a FunctionCallExpression
     *
     * $(GRAMMAR $(RULEDEF functionCallExpression):
     *       $(RULE symbol) $(RULE arguments)
     *     | $(RULE unaryExpression) $(RULE arguments)
     *     | $(RULE type) $(RULE arguments)
     *     ;)
     */
    FunctionCallExpression parseFunctionCallExpression(UnaryExpression unary = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!FunctionCallExpression;
        switch (current.type)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
        case tok!"scope":
        case tok!"pure":
        case tok!"nothrow":
            mixin(parseNodeQ!(`node.type`, `Type`));
            mixin(parseNodeQ!(`node.arguments`, `Arguments`));
            break;
        default:
            if (unary !is null)
                node.unaryExpression = unary;
            else
                mixin(parseNodeQ!(`node.unaryExpression`, `UnaryExpression`));
            if (currentIs(tok!"!"))
                mixin(parseNodeQ!(`node.templateArguments`, `TemplateArguments`));
            if (unary !is null)
                mixin(parseNodeQ!(`node.arguments`, `Arguments`));
        }
        return node;
    }

    /**
     * Parses a FunctionDeclaration
     *
     * $(GRAMMAR $(RULEDEF functionDeclaration):
     *       ($(RULE storageClass)+ | $(RULE _type)) $(LITERAL Identifier) $(RULE parameters) $(RULE memberFunctionAttribute)* ($(RULE functionBody) | $(LITERAL ';'))
     *     | ($(RULE storageClass)+ | $(RULE _type)) $(LITERAL Identifier) $(RULE templateParameters) $(RULE parameters) $(RULE memberFunctionAttribute)* $(RULE constraint)? ($(RULE functionBody) | $(LITERAL ';'))
     *     ;)
     */
    FunctionDeclaration parseFunctionDeclaration(Type type = null, bool isAuto = false,
        Attribute[] attributes = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!FunctionDeclaration;
        node.comment = comment;
        comment = null;
        StackBuffer memberFunctionAttributes;
        node.attributes = attributes;

        if (isAuto)
        {
            StackBuffer storageClasses;
            while (isStorageClass())
                if (!storageClasses.put(parseStorageClass()))
                    return null;
            ownArray(node.storageClasses, storageClasses);

            foreach (a; node.attributes)
            {
                if (a.attribute == tok!"auto")
                    node.hasAuto = true;
                else if (a.attribute == tok!"ref")
                    node.hasRef = true;
                else
                    continue;
            }
        }
        else
        {
            while (moreTokens() && currentIsMemberFunctionAttribute())
                if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                    return null;
            if (type is null)
                mixin(parseNodeQ!(`node.returnType`, `Type`));
            else
                node.returnType = type;
        }

        mixin(tokenCheck!(`node.name`, "identifier"));
        if (!currentIs(tok!"("))
        {
            error("'(' expected");
            return null;
        }
        const p = peekPastParens();
        immutable bool isTemplate = p !is null && p.type == tok!"(";

        if (isTemplate)
            mixin(parseNodeQ!(`node.templateParameters`, `TemplateParameters`));

        mixin(parseNodeQ!(`node.parameters`, `Parameters`));

        while (moreTokens() && currentIsMemberFunctionAttribute())
            if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                return null;

        if (isTemplate && currentIs(tok!"if"))
            mixin(parseNodeQ!(`node.constraint`, `Constraint`));

        if (currentIs(tok!";"))
            advance();
        else
            mixin(parseNodeQ!(`node.functionBody`, `FunctionBody`));
        ownArray(node.memberFunctionAttributes, memberFunctionAttributes);
        return node;
    }

    /**
     * Parses a FunctionLiteralExpression
     *
     * $(GRAMMAR $(RULEDEF functionLiteralExpression):
     *     | $(LITERAL 'delegate') $(RULE type)? ($(RULE parameters) $(RULE functionAttribute)*)? $(RULE functionBody)
     *     | $(LITERAL 'function') $(RULE type)? ($(RULE parameters) $(RULE functionAttribute)*)? $(RULE functionBody)
     *     | $(RULE parameters) $(RULE functionAttribute)* $(RULE functionBody)
     *     | $(RULE functionBody)
     *     | $(LITERAL Identifier) $(LITERAL '=>') $(RULE assignExpression)
     *     | $(LITERAL 'function') $(RULE type)? $(RULE parameters) $(RULE functionAttribute)* $(LITERAL '=>') $(RULE assignExpression)
     *     | $(LITERAL 'delegate') $(RULE type)? $(RULE parameters) $(RULE functionAttribute)* $(LITERAL '=>') $(RULE assignExpression)
     *     | $(RULE parameters) $(RULE functionAttribute)* $(LITERAL '=>') $(RULE assignExpression)
     *     ;)
     */
    FunctionLiteralExpression parseFunctionLiteralExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!FunctionLiteralExpression;
        node.line = current.line;
        node.column = current.column;
        if (currentIsOneOf(tok!"function", tok!"delegate"))
        {
            node.functionOrDelegate = advance().type;
            if (!currentIsOneOf(tok!"(", tok!"in", tok!"body",
                    tok!"out", tok!"{", tok!"=>"))
                mixin(parseNodeQ!(`node.returnType`, `Type`));
        }
        if (startsWith(tok!"identifier", tok!"=>"))
        {
            node.identifier = advance();
            advance(); // =>
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
            return node;
        }
        else if (currentIs(tok!"("))
        {
            mixin(parseNodeQ!(`node.parameters`, `Parameters`));
            StackBuffer memberFunctionAttributes;
            while (currentIsMemberFunctionAttribute())
            {
                auto c = allocator.setCheckpoint();
                if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                {
                    allocator.rollback(c);
                    break;
                }
            }
            ownArray(node.memberFunctionAttributes, memberFunctionAttributes);
        }
        if (currentIs(tok!"=>"))
        {
            advance();
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        }
        else
            mixin(parseNodeQ!(`node.functionBody`, `FunctionBody`));
        return node;
    }

    /**
     * Parses a GotoStatement
     *
     * $(GRAMMAR $(RULEDEF gotoStatement):
     *     $(LITERAL 'goto') ($(LITERAL Identifier) | $(LITERAL 'default') | $(LITERAL 'case') $(RULE expression)?) $(LITERAL ';')
     *     ;)
     */
    GotoStatement parseGotoStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!GotoStatement;
        mixin(tokenCheck!"goto");
        switch (current.type)
        {
        case tok!"identifier":
        case tok!"default":
            node.label = advance();
            break;
        case tok!"case":
            node.label = advance();
            if (!currentIs(tok!";"))
                mixin(parseNodeQ!(`node.expression`, `Expression`));
            break;
        default:
            error(`Identifier, "default", or "case" expected`);
            return null;
        }
        mixin(tokenCheck!";");
        return node;
    }

    /**
     * Parses an IdentifierChain
     *
     * $(GRAMMAR $(RULEDEF identifierChain):
     *     $(LITERAL Identifier) ($(LITERAL '.') $(LITERAL Identifier))*
     *     ;)
     */
    IdentifierChain parseIdentifierChain()
    {
        auto node = allocator.make!IdentifierChain;
        StackBuffer identifiers;
        while (moreTokens())
        {
            const ident = expect(tok!"identifier");
            mixin(nullCheck!`ident`);
            identifiers.put(*ident);
            if (currentIs(tok!"."))
            {
                advance();
                continue;
            }
            else
                break;
        }
        ownArray(node.identifiers, identifiers);
        return node;
    }

    /**
     * Parses an IdentifierList
     *
     * $(GRAMMAR $(RULEDEF identifierList):
     *     $(LITERAL Identifier) ($(LITERAL ',') $(LITERAL Identifier))*
     *     ;)
     */
    IdentifierList parseIdentifierList()
    {
        auto node = allocator.make!IdentifierList;
        StackBuffer identifiers;
        while (moreTokens())
        {
            const ident = expect(tok!"identifier");
            mixin(nullCheck!`ident`);
            identifiers.put(*ident);
            if (currentIs(tok!","))
            {
                advance();
                continue;
            }
            else
                break;
        }
        ownArray(node.identifiers, identifiers);
        return node;
    }

    /**
     * Parses an IdentifierOrTemplateChain
     *
     * $(GRAMMAR $(RULEDEF identifierOrTemplateChain):
     *     $(RULE identifierOrTemplateInstance) ($(LITERAL '.') $(RULE identifierOrTemplateInstance))*
     *     $(RULE identifierOrTemplateInstance) ($(LITERAL '[') $(RULE assignExpression) ($(LITERAL ']') ($(LITERAL '.') $(RULE parseIdentifierOrTemplateChain)
     *     ;)
     */
    IdentifierOrTemplateChain parseIdentifierOrTemplateChain()
    {
        auto node = allocator.make!IdentifierOrTemplateChain;
        StackBuffer identifiersOrTemplateInstances;
        while (moreTokens())
        {
            auto c = allocator.setCheckpoint();
            if (!identifiersOrTemplateInstances.put(parseIdentifierOrTemplateInstance()))
            {
                allocator.rollback(c);
                if (identifiersOrTemplateInstances.length == 0)
                    return null;
                else
                    break;
            }
            if (currentIs(tok!"["))
            {
                auto b = setBookmark();
                advance();
                if (!currentIs(tok!"]"))
                {
                    mixin(parseNodeQ!(`node.indexer`, `AssignExpression`));
                }
                expect(tok!"]");
                if (node.indexer is null)
                {
                    // [] is a TypeSuffix
                    goToBookmark(b);
                    return node;
                }
                if (!currentIs(tok!"."))
                {
                    goToBookmark(b);
                }
                else
                {
                    abandonBookmark(b);
                }
            }
            if (!currentIs(tok!"."))
                break;
            else
                advance();
        }
        ownArray(node.identifiersOrTemplateInstances, identifiersOrTemplateInstances);
        return node;
    }

    /**
     * Parses an IdentifierOrTemplateInstance
     *
     * $(GRAMMAR $(RULEDEF identifierOrTemplateInstance):
     *       $(LITERAL Identifier)
     *     | $(RULE templateInstance)
     *     ;)
     */
    IdentifierOrTemplateInstance parseIdentifierOrTemplateInstance()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!IdentifierOrTemplateInstance;
        if (peekIs(tok!"!") && !startsWith(tok!"identifier",
            tok!"!", tok!"is")
            && !startsWith(tok!"identifier", tok!"!", tok!"in"))
        {
            mixin(parseNodeQ!(`node.templateInstance`, `TemplateInstance`));
        }
        else
        {
            const ident = expect(tok!"identifier");
            mixin(nullCheck!`ident`);
            node.identifier = *ident;
        }
        return node;
    }

    /**
     * Parses an IdentityExpression
     *
     * $(GRAMMAR $(RULEDEF identityExpression):
     *     $(RULE shiftExpression) ($(LITERAL 'is') | ($(LITERAL '!') $(LITERAL 'is'))) $(RULE shiftExpression)
     *     ;)
     */
    ExpressionNode parseIdentityExpression(ExpressionNode shift = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!IdentityExpression;
        mixin(nullCheck!`node.left = shift is null ? parseShiftExpression() : shift`);
        if (currentIs(tok!"!"))
        {
            advance();
            node.negated = true;
        }
        mixin(tokenCheck!"is");
        mixin(parseNodeQ!(`node.right`, `ShiftExpression`));
        return node;
    }

    /**
     * Parses an IfStatement
     *
     * $(GRAMMAR $(RULEDEF ifStatement):
     *     $(LITERAL 'if') $(LITERAL '$(LPAREN)') $(RULE ifCondition) $(LITERAL '$(RPAREN)') $(RULE declarationOrStatement) ($(LITERAL 'else') $(RULE declarationOrStatement))?
     *$(RULEDEF ifCondition):
     *       $(LITERAL 'auto') $(LITERAL Identifier) $(LITERAL '=') $(RULE expression)
     *     | $(RULE typeConstructors) $(LITERAL Identifier) $(LITERAL '=') $(RULE expression)
     *     | $(RULE type) $(LITERAL Identifier) $(LITERAL '=') $(RULE expression)
     *     | $(RULE expression)
     *     ;)
     */
    IfStatement parseIfStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!IfStatement;
        node.line = current().line;
        node.column = current().column;
        mixin(tokenCheck!"if");
        node.startIndex = current().index;
        mixin(tokenCheck!"(");

        if (currentIs(tok!"auto"))
        {
            advance();
            const i = expect(tok!"identifier");
            if (i !is null)
                node.identifier = *i;
            expect(tok!"=");
            mixin(parseNodeQ!(`node.expression`, `Expression`));
        }
        else
        {
            // consume for TypeCtors = identifier
            if (isTypeCtor(current.type))
            {
                while (isTypeCtor(current.type))
                {
                    const prev = current.type;
                    advance();
                    if (current.type == prev)
                        warn("redundant type constructor");
                }
                // goes back for TypeCtor(Type) = identifier
                if (currentIs(tok!"("))
                    index--;
            }

            immutable b = setBookmark();
            immutable c = allocator.setCheckpoint();
            auto type = parseType();
            if (type is null || !currentIs(tok!"identifier")
                || !peekIs(tok!"="))
            {
                allocator.rollback(c);
                goToBookmark(b);
                mixin(parseNodeQ!(`node.expression`, `Expression`));
            }
            else
            {
                abandonBookmark(b);
                node.type = type;
                mixin(tokenCheck!(`node.identifier`, "identifier"));
                mixin(tokenCheck!"=");
                mixin(parseNodeQ!(`node.expression`, `Expression`));
            }
        }

        mixin(tokenCheck!")");
        if (currentIs(tok!"}"))
        {
            error("Statement expected", false);
            return node; // this line makes DCD better
        }
        mixin(parseNodeQ!(`node.thenStatement`, `DeclarationOrStatement`));
        if (currentIs(tok!"else"))
        {
            advance();
            mixin(parseNodeQ!(`node.elseStatement`, `DeclarationOrStatement`));
        }
        return node;
    }

    /**
     * Parses an ImportBind
     *
     * $(GRAMMAR $(RULEDEF importBind):
     *     $(LITERAL Identifier) ($(LITERAL '=') $(LITERAL Identifier))?
     *     ;)
     */
    ImportBind parseImportBind()
    {
        auto node = allocator.make!ImportBind;
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.left = *ident;
        if (currentIs(tok!"="))
        {
            advance();
            const id = expect(tok!"identifier");
            mixin(nullCheck!`id`);
            node.right = *id;
        }
        return node;
    }

    /**
     * Parses ImportBindings
     *
     * $(GRAMMAR $(RULEDEF importBindings):
     *     $(RULE singleImport) $(LITERAL ':') $(RULE importBind) ($(LITERAL ',') $(RULE importBind))*
     *     ;)
     */
    ImportBindings parseImportBindings(SingleImport singleImport)
    {
        auto node = allocator.make!ImportBindings;
        mixin(nullCheck!`node.singleImport = singleImport is null ? parseSingleImport() : singleImport`);
        mixin(tokenCheck!":");
        StackBuffer importBinds;
        while (moreTokens())
        {
            immutable c = allocator.setCheckpoint();
            if (importBinds.put(parseImportBind()))
            {
                if (currentIs(tok!","))
                    advance();
                else
                    break;
            }
            else
            {
                allocator.rollback(c);
                break;
            }
        }
        ownArray(node.importBinds, importBinds);
        return node;
    }

    /**
     * Parses an ImportDeclaration
     *
     * $(GRAMMAR $(RULEDEF importDeclaration):
     *       $(LITERAL 'import') $(RULE singleImport) ($(LITERAL ',') $(RULE singleImport))* ($(LITERAL ',') $(RULE importBindings))? $(LITERAL ';')
     *     | $(LITERAL 'import') $(RULE importBindings) $(LITERAL ';')
     *     ;)
     */
    ImportDeclaration parseImportDeclaration()
    {
        auto node = allocator.make!ImportDeclaration;
        node.startIndex = current().index;
        mixin(tokenCheck!"import");
        SingleImport si = parseSingleImport();
        if (si is null)
            return null;
        if (currentIs(tok!":"))
            node.importBindings = parseImportBindings(si);
        else
        {
            StackBuffer singleImports;
            singleImports.put(si);
            if (currentIs(tok!","))
            {
                advance();
                while (moreTokens())
                {
                    auto single = parseSingleImport();
                    mixin(nullCheck!`single`);
                    if (currentIs(tok!":"))
                    {
                        node.importBindings = parseImportBindings(single);
                        break;
                    }
                    else
                    {
                        singleImports.put(single);
                        if (currentIs(tok!","))
                            advance();
                        else
                            break;
                    }
                }
            }
            ownArray(node.singleImports, singleImports);
        }
        node.endIndex = (moreTokens() ? current() : previous()).index + 1;
        mixin(tokenCheck!";");
        return node;
    }

    /**
     * Parses an ImportExpression
     *
     * $(GRAMMAR $(RULEDEF importExpression):
     *     $(LITERAL 'import') $(LITERAL '$(LPAREN)') $(RULE assignExpression) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    ImportExpression parseImportExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin(simpleParse!(ImportExpression, tok!"import", tok!"(",
                "assignExpression|parseAssignExpression", tok!")"));
    }

    /**
     * Parses an Index
     *
     * $(GRAMMAR $(RULEDEF index):
     *     $(RULE assignExpression) ($(LITERAL '..') $(RULE assignExpression))?
     *     ;
     * )
     */
    Index parseIndex()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Index();
        mixin(parseNodeQ!(`node.low`, `AssignExpression`));
        if (currentIs(tok!".."))
        {
            advance();
            mixin(parseNodeQ!(`node.high`, `AssignExpression`));
        }
        return node;
    }

    /**
     * Parses an IndexExpression
     *
     * $(GRAMMAR $(RULEDEF indexExpression):
     *       $(RULE unaryExpression) $(LITERAL '[') $(LITERAL ']')
     *     | $(RULE unaryExpression) $(LITERAL '[') $(RULE index) ($(LITERAL ',') $(RULE index))* $(LITERAL ']')
     *     ;
     * )
     */
    IndexExpression parseIndexExpression(UnaryExpression unaryExpression = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!IndexExpression;
        mixin(nullCheck!`node.unaryExpression = unaryExpression is null ? parseUnaryExpression() : unaryExpression`);
        mixin(tokenCheck!"[");
        StackBuffer indexes;
        while (true)
        {
            if (!moreTokens())
            {
                error("Expected unary expression instead of EOF");
                return null;
            }
            if (currentIs(tok!"]"))
                break;
            if (!(indexes.put(parseIndex())))
                return null;
            if (currentIs(tok!","))
                advance();
            else
                break;
        }
        ownArray(node.indexes, indexes);
        advance(); // ]
        return node;
    }

    /**
     * Parses an InExpression
     *
     * $(GRAMMAR $(RULEDEF inExpression):
     *     $(RULE shiftExpression) ($(LITERAL 'in') | ($(LITERAL '!') $(LITERAL 'in'))) $(RULE shiftExpression)
     *     ;)
     */
    ExpressionNode parseInExpression(ExpressionNode shift = null)
    {
        auto node = allocator.make!InExpression;
        mixin(nullCheck!`node.left = shift is null ? parseShiftExpression() : shift`);
        if (currentIs(tok!"!"))
        {
            node.negated = true;
            advance();
        }
        mixin(tokenCheck!"in");
        mixin(parseNodeQ!(`node.right`, `ShiftExpression`));
        return node;
    }

    /**
     * Parses an InStatement
     *
     * $(GRAMMAR $(RULEDEF inStatement):
     *     $(LITERAL 'in') $(RULE blockStatement)
     *     ;)
     */
    InStatement parseInStatement()
    {
        auto node = allocator.make!InStatement;
        const i = expect(tok!"in");
        mixin(nullCheck!`i`);
        node.inTokenLocation = i.index;
        mixin(parseNodeQ!(`node.blockStatement`, `BlockStatement`));
        return node;
    }

    /**
     * Parses an Initializer
     *
     * $(GRAMMAR $(RULEDEF initializer):
     *       $(LITERAL 'void')
     *     | $(RULE nonVoidInitializer)
     *     ;)
     */
    Initializer parseInitializer()
    {
        auto node = allocator.make!Initializer;
        if (currentIs(tok!"void") && peekIsOneOf(tok!",", tok!";"))
            advance();
        else
            mixin(parseNodeQ!(`node.nonVoidInitializer`, `NonVoidInitializer`));
        return node;
    }

    /**
     * Parses an InterfaceDeclaration
     *
     * $(GRAMMAR $(RULEDEF interfaceDeclaration):
     *       $(LITERAL 'interface') $(LITERAL Identifier) $(LITERAL ';')
     *     | $(LITERAL 'interface') $(LITERAL Identifier) ($(LITERAL ':') $(RULE baseClassList))? $(RULE structBody)
     *     | $(LITERAL 'interface') $(LITERAL Identifier) $(RULE templateParameters) $(RULE constraint)? ($(LITERAL ':') $(RULE baseClassList))? $(RULE structBody)
     *     | $(LITERAL 'interface') $(LITERAL Identifier) $(RULE templateParameters) ($(LITERAL ':') $(RULE baseClassList))? $(RULE constraint)? $(RULE structBody)
     *     ;)
     */
    InterfaceDeclaration parseInterfaceDeclaration()
    {
        auto node = allocator.make!InterfaceDeclaration;
        expect(tok!"interface");
        return parseInterfaceOrClass(node);
    }

    /**
     * Parses an Invariant
     *
     * $(GRAMMAR $(RULEDEF invariant):
     *     $(LITERAL 'invariant') ($(LITERAL '$(LPAREN)') $(LITERAL '$(RPAREN)'))? $(RULE blockStatement)
     *     ;)
     */
    Invariant parseInvariant()
    {
        auto node = allocator.make!Invariant;
        node.index = current.index;
        node.line = current.line;
        mixin(tokenCheck!"invariant");
        if (currentIs(tok!"("))
        {
            advance();
            mixin(tokenCheck!")");
        }
        mixin(parseNodeQ!(`node.blockStatement`, `BlockStatement`));
        return node;
    }

    /**
     * Parses an IsExpression
     *
     * $(GRAMMAR $(RULEDEF isExpression):
     *     $(LITERAL'is') $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL identifier)? $(LITERAL '$(RPAREN)')
     *     $(LITERAL'is') $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL identifier)? $(LITERAL ':') $(RULE typeSpecialization) $(LITERAL '$(RPAREN)')
     *     $(LITERAL'is') $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL identifier)? $(LITERAL '=') $(RULE typeSpecialization) $(LITERAL '$(RPAREN)')
     *     $(LITERAL'is') $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL identifier)? $(LITERAL ':') $(RULE typeSpecialization) $(LITERAL ',') $(RULE templateParameterList) $(LITERAL '$(RPAREN)')
     *     $(LITERAL'is') $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL identifier)? $(LITERAL '=') $(RULE typeSpecialization) $(LITERAL ',') $(RULE templateParameterList) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    IsExpression parseIsExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!IsExpression;
        mixin(tokenCheck!"is");
        mixin(tokenCheck!"(");
        mixin(parseNodeQ!(`node.type`, `Type`));
        if (currentIs(tok!"identifier"))
            node.identifier = advance();
        if (currentIsOneOf(tok!"==", tok!":"))
        {
            node.equalsOrColon = advance().type;
            mixin(parseNodeQ!(`node.typeSpecialization`, `TypeSpecialization`));
            if (currentIs(tok!","))
            {
                advance();
                mixin(parseNodeQ!(`node.templateParameterList`, `TemplateParameterList`));
            }
        }
        mixin(tokenCheck!")");
        return node;
    }

    /**
     * Parses a KeyValuePair
     *
     * $(GRAMMAR $(RULEDEF keyValuePair):
     *     $(RULE assignExpression) $(LITERAL ':') $(RULE assignExpression)
     *     ;)
     */
    KeyValuePair parseKeyValuePair()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!KeyValuePair;
        mixin(parseNodeQ!(`node.key`, `AssignExpression`));
        mixin(tokenCheck!":");
        mixin(parseNodeQ!(`node.value`, `AssignExpression`));
        return node;
    }

    /**
     * Parses KeyValuePairs
     *
     * $(GRAMMAR $(RULEDEF keyValuePairs):
     *     $(RULE keyValuePair) ($(LITERAL ',') $(RULE keyValuePair))* $(LITERAL ',')?
     *     ;)
     */
    KeyValuePairs parseKeyValuePairs()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!KeyValuePairs;
        StackBuffer keyValuePairs;
        while (moreTokens())
        {
            if (!keyValuePairs.put(parseKeyValuePair()))
                return null;
            if (currentIs(tok!","))
            {
                advance();
                if (currentIs(tok!"]"))
                    break;
            }
            else
                break;
        }
        ownArray(node.keyValuePairs, keyValuePairs);
        return node;
    }

    /**
     * Parses a LabeledStatement
     *
     * $(GRAMMAR $(RULEDEF labeledStatement):
     *     $(LITERAL Identifier) $(LITERAL ':') $(RULE declarationOrStatement)?
     *     ;)
     */
    LabeledStatement parseLabeledStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!LabeledStatement;
        const ident = expect(tok!"identifier");
        mixin (nullCheck!`ident`);
        node.identifier = *ident;
        expect(tok!":");
        if (!currentIs(tok!"}"))
            mixin(parseNodeQ!(`node.declarationOrStatement`, `DeclarationOrStatement`));
        return node;
    }

    /**
     * Parses a LastCatch
     *
     * $(GRAMMAR $(RULEDEF lastCatch):
     *     $(LITERAL 'catch') $(RULE statementNoCaseNoDefault)
     *     ;)
     */
    LastCatch parseLastCatch()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!LastCatch;
        const t = expect(tok!"catch");
        mixin (nullCheck!`t`);
        node.line = t.line;
        node.column = t.column;
        mixin(parseNodeQ!(`node.statementNoCaseNoDefault`, `StatementNoCaseNoDefault`));
        return node;
    }

    /**
     * Parses a LinkageAttribute
     *
     * $(GRAMMAR $(RULEDEF linkageAttribute):
     *       $(LITERAL 'extern') $(LITERAL '$(LPAREN)') $(LITERAL Identifier) $(LITERAL '$(RPAREN)')
     *       $(LITERAL 'extern') $(LITERAL '$(LPAREN)') $(LITERAL Identifier) $(LITERAL '-') $(LITERAL Identifier) $(LITERAL '$(RPAREN)')
     *     | $(LITERAL 'extern') $(LITERAL '$(LPAREN)') $(LITERAL Identifier) $(LITERAL '++') ($(LITERAL ',') $(RULE identifierChain) | $(LITERAL 'struct') | $(LITERAL 'class'))? $(LITERAL '$(RPAREN)')
     *     ;)
     */
    LinkageAttribute parseLinkageAttribute()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!LinkageAttribute;
        mixin (tokenCheck!"extern");
        mixin (tokenCheck!"(");
        const ident = expect(tok!"identifier");
        mixin (nullCheck!`ident`);
        node.identifier = *ident;
        if (currentIs(tok!"++"))
        {
            advance();
            node.hasPlusPlus = true;
            if (currentIs(tok!","))
            {
                advance();
                if (currentIsOneOf(tok!"struct", tok!"class"))
                    node.classOrStruct = advance().type;
                else
                    mixin(parseNodeQ!(`node.identifierChain`, `IdentifierChain`));
            }
        }
        else if (currentIs(tok!"-"))
        {
            advance();
            mixin(tokenCheck!"identifier");
        }
        expect(tok!")");
        return node;
    }

    /**
     * Parses a MemberFunctionAttribute
     *
     * $(GRAMMAR $(RULEDEF memberFunctionAttribute):
     *       $(RULE functionAttribute)
     *     | $(LITERAL 'immutable')
     *     | $(LITERAL 'inout')
     *     | $(LITERAL 'shared')
     *     | $(LITERAL 'const')
     *     | $(LITERAL 'return')
     *     | $(LITERAL 'scope')
     *     ;)
     */
    MemberFunctionAttribute parseMemberFunctionAttribute()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!MemberFunctionAttribute;
        switch (current.type)
        {
        case tok!"@":
            mixin(parseNodeQ!(`node.atAttribute`, `AtAttribute`));
            break;
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
        case tok!"const":
        case tok!"pure":
        case tok!"nothrow":
        case tok!"return":
        case tok!"scope":
            node.tokenType = advance().type;
            break;
        default:
            error(`Member funtion attribute expected`);
        }
        return node;
    }

    /**
     * Parses a MixinDeclaration
     *
     * $(GRAMMAR $(RULEDEF mixinDeclaration):
     *       $(RULE mixinExpression) $(LITERAL ';')
     *     | $(RULE templateMixinExpression) $(LITERAL ';')
     *     ;)
     */
    MixinDeclaration parseMixinDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!MixinDeclaration;
        if (peekIsOneOf(tok!"identifier", tok!"typeof", tok!"."))
            mixin(parseNodeQ!(`node.templateMixinExpression`, `TemplateMixinExpression`));
        else if (peekIs(tok!"("))
            mixin(parseNodeQ!(`node.mixinExpression`, `MixinExpression`));
        else
        {
            error(`"(" or identifier expected`);
            return null;
        }
        expect(tok!";");
        return node;
    }

    /**
     * Parses a MixinExpression
     *
     * $(GRAMMAR $(RULEDEF mixinExpression):
     *     $(LITERAL 'mixin') $(LITERAL '$(LPAREN)') $(RULE assignExpression) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    MixinExpression parseMixinExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!MixinExpression;
        expect(tok!"mixin");
        expect(tok!"(");
        mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        expect(tok!")");
        return node;
    }

    /**
     * Parses a MixinTemplateDeclaration
     *
     * $(GRAMMAR $(RULEDEF mixinTemplateDeclaration):
     *     $(LITERAL 'mixin') $(RULE templateDeclaration)
     *     ;)
     */
    MixinTemplateDeclaration parseMixinTemplateDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!MixinTemplateDeclaration;
        mixin(tokenCheck!"mixin");
        mixin(parseNodeQ!(`node.templateDeclaration`, `TemplateDeclaration`));
        return node;
    }

    /**
     * Parses a MixinTemplateName
     *
     * $(GRAMMAR $(RULEDEF mixinTemplateName):
     *       $(RULE symbol)
     *     | $(RULE typeofExpression) $(LITERAL '.') $(RULE identifierOrTemplateChain)
     *     ;)
     */
    MixinTemplateName parseMixinTemplateName()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!MixinTemplateName;
        if (currentIs(tok!"typeof"))
        {
            mixin(parseNodeQ!(`node.typeofExpression`, `TypeofExpression`));
            expect(tok!".");
            mixin(parseNodeQ!(`node.identifierOrTemplateChain`, `IdentifierOrTemplateChain`));
        }
        else
            mixin(parseNodeQ!(`node.symbol`, `Symbol`));
        return node;
    }

    /**
     * Parses a Module
     *
     * $(GRAMMAR $(RULEDEF module):
     *     $(RULE moduleDeclaration)? $(RULE declaration)*
     *     ;)
     */
    Module parseModule()
    out (retVal)
    {
        assert(retVal !is null);
    }
    body
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        Module m = allocator.make!Module;
        bool isScript;
        bool isModule;
        if (currentIs(tok!"scriptLine")){
            isScript = true;
            m.scriptLine = advance();
        }
        bool isDeprecatedModule;
        if (currentIs(tok!"deprecated"))
        {
            immutable b = setBookmark();
            advance();
            if (currentIs(tok!"("))
                skipParens();
            isDeprecatedModule = currentIs(tok!"module");
            goToBookmark(b);
        }
        if (currentIs(tok!"module") || isDeprecatedModule) {
            immutable c = allocator.setCheckpoint();
            isModule = true;
            m.moduleDeclaration = parseModuleDeclaration();
            if (m.moduleDeclaration is null)
                allocator.rollback(c);
        }else{
            warn(("WARN: file '%s' does not seem to be a module (no 'module' declaration found);"
                  ~ " this is syntactically acceptable, but the instrumenter may not find it all that amusing.").format(fileName));
        }

        StackBuffer declarations;
        while (moreTokens())
        {
            immutable c = allocator.setCheckpoint();
            if (!declarations.put(parseDeclaration(true, true)))
                allocator.rollback(c);
        }
        ownArray(m.declarations, declarations);
        return m;
    }

    /**
     * Parses a ModuleDeclaration
     *
     * $(GRAMMAR $(RULEDEF moduleDeclaration):
     *     $(RULE deprecated)? $(LITERAL 'module') $(RULE identifierChain) $(LITERAL ';')
     *     ;)
     */
    ModuleDeclaration parseModuleDeclaration()
    {
        auto node = allocator.make!ModuleDeclaration;
        if (currentIs(tok!"deprecated"))
            mixin(parseNodeQ!(`node.deprecated_`, `Deprecated`));
        node.startLocation = current().index;
        const start = expect(tok!"module");
        mixin(nullCheck!`start`);
        mixin(parseNodeQ!(`node.moduleName`, `IdentifierChain`));
        node.endLocation = current().index;

        node.comment = start.comment;
        if (node.comment is null)
            node.comment = start.trailingComment;
        comment = null;
        expect(tok!";");
        return node;
    }

    /**
     * Parses a MulExpression.
     *
     * $(GRAMMAR $(RULEDEF mulExpression):
     *       $(RULE powExpression)
     *     | $(RULE mulExpression) ($(LITERAL '*') | $(LITERAL '/') | $(LITERAL '%')) $(RULE powExpression)
     *     ;)
     */
    ExpressionNode parseMulExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(MulExpression, PowExpression,
            tok!"*", tok!"/", tok!"%")();
    }

    /**
     * Parses a NewAnonClassExpression
     *
     * $(GRAMMAR $(RULEDEF newAnonClassExpression):
     *     $(LITERAL 'new') $(RULE arguments)? $(LITERAL 'class') $(RULE arguments)? $(RULE baseClassList)? $(RULE structBody)
     *     ;)
     */
    NewAnonClassExpression parseNewAnonClassExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!NewAnonClassExpression;
        expect(tok!"new");
        if (currentIs(tok!"("))
            mixin(parseNodeQ!(`node.allocatorArguments`, `Arguments`));
        expect(tok!"class");
        if (currentIs(tok!"("))
            mixin(parseNodeQ!(`node.constructorArguments`, `Arguments`));
        if (!currentIs(tok!"{"))
            mixin(parseNodeQ!(`node.baseClassList`, `BaseClassList`));
        mixin(parseNodeQ!(`node.structBody`, `StructBody`));
        return node;
    }

    /**
     * Parses a NewExpression
     *
     * $(GRAMMAR $(RULEDEF newExpression):
     *       $(LITERAL 'new') $(RULE type) (($(LITERAL '[') $(RULE assignExpression) $(LITERAL ']')) | $(RULE arguments))?
     *     | $(RULE newAnonClassExpression)
     *     ;)
     */
    NewExpression parseNewExpression()
    {
        // Parse ambiguity.
        // auto a = new int[10];
        //              ^^^^^^^
        // auto a = new int[10];
        //              ^^^****
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!NewExpression;
        if (peekIsOneOf(tok!"class", tok!"("))
            mixin(parseNodeQ!(`node.newAnonClassExpression`, `NewAnonClassExpression`));
        else
        {
            expect(tok!"new");
            mixin(parseNodeQ!(`node.type`, `Type`));
            if (currentIs(tok!"["))
            {
                advance();
                mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
                expect(tok!"]");
            }
            else if (currentIs(tok!"("))
                mixin(parseNodeQ!(`node.arguments`, `Arguments`));
        }
        return node;
    }

    /**
     * Parses a NonVoidInitializer
     *
     * $(GRAMMAR $(RULEDEF nonVoidInitializer):
     *       $(RULE assignExpression)
     *     | $(RULE arrayInitializer)
     *     | $(RULE structInitializer)
     *     ;)
     */
    NonVoidInitializer parseNonVoidInitializer()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!NonVoidInitializer;
        if (currentIs(tok!"{"))
        {
            const b = peekPastBraces();
            if (b !is null && (b.type == tok!"("))
                mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
            else
            {
                assert (currentIs(tok!"{"));
                auto m = setBookmark();
                auto initializer = parseStructInitializer();
                if (initializer !is null)
                {
                    node.structInitializer = initializer;
                    abandonBookmark(m);
                }
                else
                {
                    goToBookmark(m);
                    mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
                }
            }
        }
        else if (currentIs(tok!"["))
        {
            const b = peekPastBrackets();
            if (b !is null && (b.type == tok!","
                || b.type == tok!")"
                || b.type == tok!"]"
                || b.type == tok!"}"
                || b.type == tok!";"))
            {
                mixin(parseNodeQ!(`node.arrayInitializer`, `ArrayInitializer`));
            }
            else
                mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        }
        else
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        if (node.assignExpression is null && node.arrayInitializer is null
                && node.structInitializer is null)
            return null;
        return node;
    }

    /**
     * Parses Operands
     *
     * $(GRAMMAR $(RULEDEF operands):
     *       $(RULE asmExp)
     *     | $(RULE asmExp) $(LITERAL ',') $(RULE operands)
     *     ;)
     */
    Operands parseOperands()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        Operands node = allocator.make!Operands;
        StackBuffer expressions;
        while (true)
        {
            if (!expressions.put(parseAsmExp()))
                return null;
            if (currentIs(tok!","))
                advance();
            else
                break;
        }
        ownArray(node.operands, expressions);
        return node;
    }

    /**
     * Parses an OrExpression
     *
     * $(GRAMMAR $(RULEDEF orExpression):
     *       $(RULE xorExpression)
     *     | $(RULE orExpression) $(LITERAL '|') $(RULE xorExpression)
     *     ;)
     */
    ExpressionNode parseOrExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(OrExpression, XorExpression,
            tok!"|")();
    }

    /**
     * Parses an OrOrExpression
     *
     * $(GRAMMAR $(RULEDEF orOrExpression):
     *       $(RULE andAndExpression)
     *     | $(RULE orOrExpression) $(LITERAL '||') $(RULE andAndExpression)
     *     ;)
     */
    ExpressionNode parseOrOrExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(OrOrExpression, AndAndExpression,
            tok!"||")();
    }

    /**
     * Parses an OutStatement
     *
     * $(GRAMMAR $(RULEDEF outStatement):
     *     $(LITERAL 'out') ($(LITERAL '$(LPAREN)') $(LITERAL Identifier) $(LITERAL '$(RPAREN)'))? $(RULE blockStatement)
     *     ;)
     */
    OutStatement parseOutStatement()
    {
        auto node = allocator.make!OutStatement;
        const o = expect(tok!"out");
        mixin(nullCheck!`o`);
        node.outTokenLocation = o.index;
        if (currentIs(tok!"("))
        {
            advance();
            const ident = expect(tok!"identifier");
            mixin (nullCheck!`ident`);
            node.parameter = *ident;
            expect(tok!")");
        }
        mixin(parseNodeQ!(`node.blockStatement`, `BlockStatement`));
        return node;
    }

    /**
     * Parses a Parameter
     *
     * $(GRAMMAR $(RULEDEF parameter):
     *     $(RULE parameterAttribute)* $(RULE type)
     *     $(RULE parameterAttribute)* $(RULE type) $(LITERAL Identifier)? $(LITERAL '...')
     *     $(RULE parameterAttribute)* $(RULE type) $(LITERAL Identifier)? ($(LITERAL '=') $(RULE assignExpression))?
     *     ;)
     */
    Parameter parseParameter()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Parameter;
        StackBuffer parameterAttributes;
        while (moreTokens())
        {
            IdType type = parseParameterAttribute(false);
            if (type == tok!"")
                break;
            else
                parameterAttributes.put(type);
        }
        ownArray(node.parameterAttributes, parameterAttributes);
        mixin(parseNodeQ!(`node.type`, `Type`));
        if (currentIs(tok!"identifier"))
        {
            node.name = advance();
            if (currentIs(tok!"..."))
            {
                advance();
                node.vararg = true;
            }
            else if (currentIs(tok!"="))
            {
                advance();
                mixin(parseNodeQ!(`node.default_`, `AssignExpression`));
            }
            else if (currentIs(tok!"["))
            {
                StackBuffer typeSuffixes;
                while(moreTokens() && currentIs(tok!"["))
                    if (!typeSuffixes.put(parseTypeSuffix()))
                        return null;
                ownArray(node.cstyle, typeSuffixes);
            }
        }
        else if (currentIs(tok!"..."))
        {
            node.vararg = true;
            advance();
        }
        else if (currentIs(tok!"="))
        {
            advance();
            mixin(parseNodeQ!(`node.default_`, `AssignExpression`));
        }
        return node;
    }

    /**
     * Parses a ParameterAttribute
     *
     * $(GRAMMAR $(RULEDEF parameterAttribute):
     *       $(RULE typeConstructor)
     *     | $(LITERAL 'final')
     *     | $(LITERAL 'in')
     *     | $(LITERAL 'lazy')
     *     | $(LITERAL 'out')
     *     | $(LITERAL 'ref')
     *     | $(LITERAL 'scope')
     *     | $(LITERAL 'auto')
     *     | $(LITERAL 'return')
     *     ;)
     */
    IdType parseParameterAttribute(bool validate = false)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        switch (current.type)
        {
        case tok!"immutable":
        case tok!"shared":
        case tok!"const":
        case tok!"inout":
            if (peekIs(tok!"("))
                return tok!"";
            else
                goto case;
        case tok!"final":
        case tok!"in":
        case tok!"lazy":
        case tok!"out":
        case tok!"ref":
        case tok!"scope":
        case tok!"auto":
        case tok!"return":
            return advance().type;
        default:
            if (validate)
                error("Parameter attribute expected");
            return tok!"";
        }
    }

    /**
     * Parses Parameters
     *
     * $(GRAMMAR $(RULEDEF parameters):
     *       $(LITERAL '$(LPAREN)') $(RULE parameter) ($(LITERAL ',') $(RULE parameter))* ($(LITERAL ',') $(LITERAL '...'))? $(LITERAL '$(RPAREN)')
     *     | $(LITERAL '$(LPAREN)') $(LITERAL '...') $(LITERAL '$(RPAREN)')
     *     | $(LITERAL '$(LPAREN)') $(LITERAL '$(RPAREN)')
     *     ;)
     */
    Parameters parseParameters()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Parameters;
        mixin(tokenCheck!"(");

        if (currentIs(tok!")"))
        {
                advance(); // )
                return node;
        }
        if (currentIs(tok!"..."))
        {
            advance();
            node.hasVarargs = true;
            mixin(tokenCheck!")");
                return node;
        }
        StackBuffer parameters;
        while (moreTokens())
        {
            if (currentIs(tok!"..."))
            {
                advance();
                node.hasVarargs = true;
                break;
            }
            if (currentIs(tok!")"))
                break;
            if (!parameters.put(parseParameter()))
                return null;
            if (currentIs(tok!","))
                advance();
            else
                break;
        }
        ownArray(node.parameters, parameters);
        mixin(tokenCheck!")");
        return node;
    }

    /**
     * Parses a Postblit
     *
     * $(GRAMMAR $(RULEDEF postblit):
     *     $(LITERAL 'this') $(LITERAL '$(LPAREN)') $(LITERAL 'this') $(LITERAL '$(RPAREN)') $(RULE memberFunctionAttribute)* ($(RULE functionBody) | $(LITERAL ';'))
     *     ;)
     */
    Postblit parsePostblit()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Postblit;
        node.line = current.line;
        node.column = current.column;
        node.location = current.index;
        index += 4;
        StackBuffer memberFunctionAttributes;
        while (currentIsMemberFunctionAttribute())
            if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                return null;
        ownArray(node.memberFunctionAttributes, memberFunctionAttributes);
        if (currentIs(tok!";"))
            advance();
        else
            mixin(parseNodeQ!(`node.functionBody`, `FunctionBody`));
        return node;
    }

    /**
     * Parses a PowExpression
     *
     * $(GRAMMAR $(RULEDEF powExpression):
     *       $(RULE unaryExpression)
     *     | $(RULE powExpression) $(LITERAL '^^') $(RULE unaryExpression)
     *     ;)
     */
    ExpressionNode parsePowExpression()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(PowExpression, UnaryExpression,
            tok!"^^")();
    }

    /**
     * Parses a PragmaDeclaration
     *
     * $(GRAMMAR $(RULEDEF pragmaDeclaration):
     *     $(RULE pragmaExpression) $(LITERAL ';')
     *     ;)
     */
    PragmaDeclaration parsePragmaDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin(simpleParse!(PragmaDeclaration, "pragmaExpression|parsePragmaExpression", tok!";"));
    }

    /**
     * Parses a PragmaExpression
     *
     * $(GRAMMAR $(RULEDEF pragmaExpression):
     *     $(RULE 'pragma') $(LITERAL '$(LPAREN)') $(LITERAL Identifier) ($(LITERAL ',') $(RULE argumentList))? $(LITERAL '$(RPAREN)')
     *     ;)
     */
    PragmaExpression parsePragmaExpression()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!PragmaExpression;
        expect(tok!"pragma");
        expect(tok!"(");
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.identifier = *ident;
        if (currentIs(tok!","))
        {
            advance();
            mixin(parseNodeQ!(`node.argumentList`, `ArgumentList`));
        }
        expect(tok!")");
        return node;
    }

    /**
     * Parses a PragmaStatement
     *
     * $(GRAMMAR $(RULEDEF pragmaStatement):
     *        $(RULE pragmaExpression) $(RULE statement)
     *      | $(RULE pragmaExpression) $(RULE blockStatement)
     *      | $(RULE pragmaExpression) $(LITERAL ';')
     */
    PragmaStatement parsePragmaStatement()
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!PragmaStatement;
        mixin(parseNodeQ!(`node.pragmaExpression`, `PragmaExpression`));
        if (current == tok!"{")
        {
            mixin(parseNodeQ!(`node.blockStatement`, `BlockStatement`));
        }
        else if (current == tok!";")
        {
            advance();
        }
        else
        {
            mixin(parseNodeQ!(`node.statement`, `Statement`));
        }
        return node;
    }

    /**
     * Parses a PrimaryExpression
     *
     * $(GRAMMAR $(RULEDEF primaryExpression):
     *       $(RULE identifierOrTemplateInstance)
     *     | $(LITERAL '.') $(RULE identifierOrTemplateInstance)
     *     | $(RULE typeConstructor) $(LITERAL '$(LPAREN)') $(RULE basicType) $(LITERAL '$(RPAREN)') $(LITERAL '.') $(LITERAL Identifier)
     *     | $(RULE basicType) $(LITERAL '.') $(LITERAL Identifier)
     *     | $(RULE basicType) $(RULE arguments)
     *     | $(RULE typeofExpression)
     *     | $(RULE typeidExpression)
     *     | $(RULE vector)
     *     | $(RULE arrayLiteral)
     *     | $(RULE assocArrayLiteral)
     *     | $(LITERAL '$(LPAREN)') $(RULE expression) $(LITERAL '$(RPAREN)')
     *     | $(RULE isExpression)
     *     | $(RULE functionLiteralExpression)
     *     | $(RULE traitsExpression)
     *     | $(RULE mixinExpression)
     *     | $(RULE importExpression)
     *     | $(LITERAL '$')
     *     | $(LITERAL 'this')
     *     | $(LITERAL 'super')
     *     | $(LITERAL '_null')
     *     | $(LITERAL '_true')
     *     | $(LITERAL '_false')
     *     | $(LITERAL '___DATE__')
     *     | $(LITERAL '___TIME__')
     *     | $(LITERAL '___TIMESTAMP__')
     *     | $(LITERAL '___VENDOR__')
     *     | $(LITERAL '___VERSION__')
     *     | $(LITERAL '___FILE__')
     *     | $(LITERAL '___LINE__')
     *     | $(LITERAL '___MODULE__')
     *     | $(LITERAL '___FUNCTION__')
     *     | $(LITERAL '___PRETTY_FUNCTION__')
     *     | $(LITERAL IntegerLiteral)
     *     | $(LITERAL FloatLiteral)
     *     | $(LITERAL StringLiteral)+
     *     | $(LITERAL CharacterLiteral)
     *     ;)
     */
    PrimaryExpression parsePrimaryExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!PrimaryExpression;
        if (!moreTokens())
        {
            error("Expected primary statement instead of EOF");
            return null;
        }
        switch (current.type)
        {
        case tok!".":
            node.dot = advance();
            goto case;
        case tok!"identifier":
            if (peekIs(tok!"=>"))
                mixin(parseNodeQ!(`node.functionLiteralExpression`, `FunctionLiteralExpression`));
            else
                mixin(parseNodeQ!(`node.identifierOrTemplateInstance`, `IdentifierOrTemplateInstance`));
            break;
        case tok!"immutable":
        case tok!"const":
        case tok!"inout":
        case tok!"shared":
            {
                advance();
                expect(tok!"(");
                mixin(parseNodeQ!(`node.type`, `Type`));
                expect(tok!")");
                expect(tok!".");
                const ident = expect(tok!"identifier");
                if (ident !is null)
                    node.primary = *ident;
                break;
            }
		foreach (B; BasicTypes) { case B: }
            node.basicType = advance();
            if (currentIs(tok!"."))
            {
                advance();
                const t = expect(tok!"identifier");
                if (t !is null)
                    node.primary = *t;
            }
            else if (currentIs(tok!"("))
                mixin(parseNodeQ!(`node.arguments`, `Arguments`));
            break;
        case tok!"function":
        case tok!"delegate":
        case tok!"{":
        case tok!"in":
        case tok!"out":
        case tok!"body":
            mixin(parseNodeQ!(`node.functionLiteralExpression`, `FunctionLiteralExpression`));
            break;
        case tok!"typeof":
            mixin(parseNodeQ!(`node.typeofExpression`, `TypeofExpression`));
            break;
        case tok!"typeid":
            mixin(parseNodeQ!(`node.typeidExpression`, `TypeidExpression`));
            break;
        case tok!"__vector":
            mixin(parseNodeQ!(`node.vector`, `Vector`));
            break;
        case tok!"[":
            if (isAssociativeArrayLiteral())
                mixin(parseNodeQ!(`node.assocArrayLiteral`, `AssocArrayLiteral`));
            else
                mixin(parseNodeQ!(`node.arrayLiteral`, `ArrayLiteral`));
            break;
        case tok!"(":
            immutable b = setBookmark();
            skipParens();
            while (isAttribute())
                parseAttribute();
            if (currentIsOneOf(tok!"=>", tok!"{"))
            {
                goToBookmark(b);
                mixin(parseNodeQ!(`node.functionLiteralExpression`, `FunctionLiteralExpression`));
            }
            else
            {
                goToBookmark(b);
                advance();
                mixin(parseNodeQ!(`node.expression`, `Expression`));
                mixin(tokenCheck!")");
            }
            break;
        case tok!"is":
            mixin(parseNodeQ!(`node.isExpression`, `IsExpression`));
            break;
        case tok!"__traits":
            mixin(parseNodeQ!(`node.traitsExpression`, `TraitsExpression`));
            break;
        case tok!"mixin":
            mixin(parseNodeQ!(`node.mixinExpression`, `MixinExpression`));
            break;
        case tok!"import":
            mixin(parseNodeQ!(`node.importExpression`, `ImportExpression`));
            break;
        case tok!"this":
        case tok!"super":
		foreach (L; Literals) { case L: }
            if (currentIsOneOf(tok!"stringLiteral", tok!"wstringLiteral", tok!"dstringLiteral"))
            {
                node.primary = advance();
                bool alreadyWarned = false;
                while (currentIsOneOf(tok!"stringLiteral", tok!"wstringLiteral",
                    tok!"dstringLiteral"))
                {
                    if (!alreadyWarned)
                    {
                        warn("Implicit concatenation of string literals");
                        alreadyWarned = true;
                    }
                    node.primary.text ~= advance().text;
                }
            }
            else
                node.primary = advance();
            break;
        default:
            error("Primary expression expected");
            return null;
        }
        return node;
    }

    /**
     * Parses a Register
     *
     * $(GRAMMAR $(RULEDEF register):
     *       $(LITERAL Identifier)
     *     | $(LITERAL Identifier) $(LITERAL '$(LPAREN)') $(LITERAL IntegerLiteral) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    Register parseRegister()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Register;
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.identifier = *ident;
        if (currentIs(tok!"("))
        {
            advance();
            const intLit = expect(tok!"intLiteral");
            mixin(nullCheck!`intLit`);
            node.intLiteral = *intLit;
            expect(tok!")");
        }
        return node;
    }

    /**
     * Parses a RelExpression
     *
     * $(GRAMMAR $(RULEDEF relExpression):
     *       $(RULE shiftExpression)
     *     | $(RULE relExpression) $(RULE relOperator) $(RULE shiftExpression)
     *     ;
     *$(RULEDEF relOperator):
     *       $(LITERAL '<')
     *     | $(LITERAL '<=')
     *     | $(LITERAL '>')
     *     | $(LITERAL '>=')
     *     | $(LITERAL '!<>=')
     *     | $(LITERAL '!<>')
     *     | $(LITERAL '<>')
     *     | $(LITERAL '<>=')
     *     | $(LITERAL '!>')
     *     | $(LITERAL '!>=')
     *     | $(LITERAL '!<')
     *     | $(LITERAL '!<=')
     *     ;)
     */
    ExpressionNode parseRelExpression(ExpressionNode shift)
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(RelExpression, ShiftExpression,
            tok!"<", tok!"<=", tok!">", tok!">=", tok!"!<>=", tok!"!<>",
            tok!"<>", tok!"<>=", tok!"!>", tok!"!>=", tok!"!>=", tok!"!<",
            tok!"!<=")(shift);
    }

    /**
     * Parses a ReturnStatement
     *
     * $(GRAMMAR $(RULEDEF returnStatement):
     *     $(LITERAL 'return') $(RULE expression)? $(LITERAL ';')
     *     ;)
     */
    ReturnStatement parseReturnStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ReturnStatement;
        const start = expect(tok!"return");
        mixin(nullCheck!`start`);
        node.startLocation = start.index;
        if (!currentIs(tok!";"))
            mixin(parseNodeQ!(`node.expression`, `Expression`));
        const semicolon = expect(tok!";");
        mixin(nullCheck!`semicolon`);
        node.endLocation = semicolon.index;
        return node;
    }

    /**
     * Parses a ScopeGuardStatement
     *
     * $(GRAMMAR $(RULEDEF scopeGuardStatement):
     *     $(LITERAL 'scope') $(LITERAL '$(LPAREN)') $(LITERAL Identifier) $(LITERAL '$(RPAREN)') $(RULE statementNoCaseNoDefault)
     *     ;)
     */
    ScopeGuardStatement parseScopeGuardStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ScopeGuardStatement;
        expect(tok!"scope");
        expect(tok!"(");
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.identifier = *ident;
        expect(tok!")");
        mixin(parseNodeQ!(`node.statementNoCaseNoDefault`, `StatementNoCaseNoDefault`));
        return node;
    }

    /**
     * Parses a SharedStaticConstructor
     *
     * $(GRAMMAR $(RULEDEF sharedStaticConstructor):
     *     $(LITERAL 'shared') $(LITERAL 'static') $(LITERAL 'this') $(LITERAL '$(LPAREN)') $(LITERAL '$(RPAREN)') $(RULE MemberFunctionAttribute)* ($(RULE functionBody) | $(LITERAL ";"))
     *     ;)
     */
    SharedStaticConstructor parseSharedStaticConstructor()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!SharedStaticConstructor;
        node.location = current().index;
        mixin(tokenCheck!"shared");
        mixin(tokenCheck!"static");
        return parseStaticCtorDtorCommon(node);
    }

    /**
     * Parses a SharedStaticDestructor
     *
     * $(GRAMMAR $(RULEDEF sharedStaticDestructor):
     *     $(LITERAL 'shared') $(LITERAL 'static') $(LITERAL '~') $(LITERAL 'this') $(LITERAL '$(LPAREN)') $(LITERAL '$(RPAREN)') $(RULE MemberFunctionAttribute)* ($(RULE functionBody) | $(LITERAL ";"))
     *     ;)
     */
    SharedStaticDestructor parseSharedStaticDestructor()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!SharedStaticDestructor;
        node.location = current().index;
        mixin(tokenCheck!"shared");
        mixin(tokenCheck!"static");
        mixin(tokenCheck!"~");
        return parseStaticCtorDtorCommon(node);
    }

    /**
     * Parses a ShiftExpression
     *
     * $(GRAMMAR $(RULEDEF shiftExpression):
     *       $(RULE addExpression)
     *     | $(RULE shiftExpression) ($(LITERAL '<<') | $(LITERAL '>>') | $(LITERAL '>>>')) $(RULE addExpression)
     *     ;)
     */
    ExpressionNode parseShiftExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(ShiftExpression, AddExpression,
            tok!"<<", tok!">>", tok!">>>")();
    }

    /**
     * Parses a SingleImport
     *
     * $(GRAMMAR $(RULEDEF singleImport):
     *     ($(LITERAL Identifier) $(LITERAL '='))? $(RULE identifierChain)
     *     ;)
     */
    SingleImport parseSingleImport()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!SingleImport;
        if (startsWith(tok!"identifier", tok!"="))
        {
            node.rename = advance(); // identifier
            advance(); // =
        }
        mixin(parseNodeQ!(`node.identifierChain`, `IdentifierChain`));
        if (node.identifierChain is null)
            return null;
        return node;
    }

    /**
     * Parses a Statement
     *
     * $(GRAMMAR $(RULEDEF statement):
     *       $(RULE statementNoCaseNoDefault)
     *     | $(RULE caseStatement)
     *     | $(RULE caseRangeStatement)
     *     | $(RULE defaultStatement)
     *     ;)
     */
    Statement parseStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Statement;
        if (!moreTokens())
        {
            error("Expected statement instead of EOF");
            return null;
        }
        switch (current.type)
        {
        case tok!"case":
            advance();
            auto argumentList = parseArgumentList();
            if (argumentList is null)
                return null;
            if (argumentList.items.length == 1 && startsWith(tok!":", tok!".."))
                node.caseRangeStatement = parseCaseRangeStatement(argumentList.items[0]);
            else
                node.caseStatement = parseCaseStatement(argumentList);
            break;
        case tok!"default":
            mixin(parseNodeQ!(`node.defaultStatement`, `DefaultStatement`));
            break;
        default:
            mixin(parseNodeQ!(`node.statementNoCaseNoDefault`, `StatementNoCaseNoDefault`));
            break;
        }
        return node;
    }

    /**
     * Parses a StatementNoCaseNoDefault
     *
     * $(GRAMMAR $(RULEDEF statementNoCaseNoDefault):
     *       $(RULE labeledStatement)
     *     | $(RULE blockStatement)
     *     | $(RULE ifStatement)
     *     | $(RULE whileStatement)
     *     | $(RULE doStatement)
     *     | $(RULE forStatement)
     *     | $(RULE foreachStatement)
     *     | $(RULE switchStatement)
     *     | $(RULE finalSwitchStatement)
     *     | $(RULE continueStatement)
     *     | $(RULE breakStatement)
     *     | $(RULE returnStatement)
     *     | $(RULE gotoStatement)
     *     | $(RULE withStatement)
     *     | $(RULE synchronizedStatement)
     *     | $(RULE tryStatement)
     *     | $(RULE throwStatement)
     *     | $(RULE scopeGuardStatement)
     *     | $(RULE pragmaStatement)
     *     | $(RULE asmStatement)
     *     | $(RULE conditionalStatement)
     *     | $(RULE staticAssertStatement)
     *     | $(RULE versionSpecification)
     *     | $(RULE debugSpecification)
     *     | $(RULE expressionStatement)
     *     ;)
     */
    StatementNoCaseNoDefault parseStatementNoCaseNoDefault()
    {
    mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StatementNoCaseNoDefault;
        node.startLocation = current().index;
        switch (current.type)
        {
        case tok!"{":
            mixin(parseNodeQ!(`node.blockStatement`, `BlockStatement`));
            break;
        case tok!"if":
            mixin(parseNodeQ!(`node.ifStatement`, `IfStatement`));
            break;
        case tok!"while":
            mixin(parseNodeQ!(`node.whileStatement`, `WhileStatement`));
            break;
        case tok!"do":
            mixin(parseNodeQ!(`node.doStatement`, `DoStatement`));
            break;
        case tok!"for":
            mixin(parseNodeQ!(`node.forStatement`, `ForStatement`));
            break;
        case tok!"foreach":
        case tok!"foreach_reverse":
            mixin(parseNodeQ!(`node.foreachStatement`, `ForeachStatement`));
            break;
        case tok!"switch":
            mixin(parseNodeQ!(`node.switchStatement`, `SwitchStatement`));
            break;
        case tok!"continue":
            mixin(parseNodeQ!(`node.continueStatement`, `ContinueStatement`));
            break;
        case tok!"break":
            mixin(parseNodeQ!(`node.breakStatement`, `BreakStatement`));
            break;
        case tok!"return":
            mixin(parseNodeQ!(`node.returnStatement`, `ReturnStatement`));
            break;
        case tok!"goto":
            mixin(parseNodeQ!(`node.gotoStatement`, `GotoStatement`));
            break;
        case tok!"with":
            mixin(parseNodeQ!(`node.withStatement`, `WithStatement`));
            break;
        case tok!"synchronized":
            mixin(parseNodeQ!(`node.synchronizedStatement`, `SynchronizedStatement`));
            break;
        case tok!"try":
            mixin(parseNodeQ!(`node.tryStatement`, `TryStatement`));
            break;
        case tok!"throw":
            mixin(parseNodeQ!(`node.throwStatement`, `ThrowStatement`));
            break;
        case tok!"scope":
            mixin(parseNodeQ!(`node.scopeGuardStatement`, `ScopeGuardStatement`));
            break;
        case tok!"asm":
            mixin(parseNodeQ!(`node.asmStatement`, `AsmStatement`));
            break;
        case tok!"pragma":
            mixin(parseNodeQ!(`node.pragmaStatement`, `PragmaStatement`));
            break;
        case tok!"final":
            if (peekIs(tok!"switch"))
            {
                mixin(parseNodeQ!(`node.finalSwitchStatement`, `FinalSwitchStatement`));
                break;
            }
            else
            {
                error(`"switch" expected`);
                return null;
            }
        case tok!"debug":
            if (peekIs(tok!"="))
                mixin(parseNodeQ!(`node.debugSpecification`, `DebugSpecification`));
            else
                mixin(parseNodeQ!(`node.conditionalStatement`, `ConditionalStatement`));
            break;
        case tok!"version":
            if (peekIs(tok!"="))
                mixin(parseNodeQ!(`node.versionSpecification`, `VersionSpecification`));
            else
                mixin(parseNodeQ!(`node.conditionalStatement`, `ConditionalStatement`));
            break;
        case tok!"static":
            if (peekIs(tok!"if"))
                mixin(parseNodeQ!(`node.conditionalStatement`, `ConditionalStatement`));
            else if (peekIs(tok!"assert"))
                mixin(parseNodeQ!(`node.staticAssertStatement`, `StaticAssertStatement`));
            else
            {
                error("'if' or 'assert' expected.");
                return null;
            }
            break;
        case tok!"identifier":
            if (peekIs(tok!":"))
            {
                mixin(parseNodeQ!(`node.labeledStatement`, `LabeledStatement`));
                break;
            }
            goto default;
        case tok!"delete":
        case tok!"assert":
        default:
            mixin(parseNodeQ!(`node.expressionStatement`, `ExpressionStatement`));
            break;
        }
        node.endLocation = tokens[index - 1].index;
        return node;
    }

    /**
     * Parses a StaticAssertDeclaration
     *
     * $(GRAMMAR $(RULEDEF staticAssertDeclaration):
     *     $(RULE staticAssertStatement)
     *     ;)
     */
    StaticAssertDeclaration parseStaticAssertDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin(simpleParse!(StaticAssertDeclaration,
            "staticAssertStatement|parseStaticAssertStatement"));
    }


    /**
     * Parses a StaticAssertStatement
     *
     * $(GRAMMAR $(RULEDEF staticAssertStatement):
     *     $(LITERAL 'static') $(RULE assertExpression) $(LITERAL ';')
     *     ;)
     */
    StaticAssertStatement parseStaticAssertStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin(simpleParse!(StaticAssertStatement,
            tok!"static", "assertExpression|parseAssertExpression", tok!";"));
    }

    /**
     * Parses a StaticConstructor
     *
     * $(GRAMMAR $(RULEDEF staticConstructor):
     *     $(LITERAL 'static') $(LITERAL 'this') $(LITERAL '$(LPAREN)') $(LITERAL '$(RPAREN)') $(RULE memberFunctionAttribute)* ($(RULE functionBody) | $(LITERAL ";"))
     *     ;)
     */
    StaticConstructor parseStaticConstructor()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StaticConstructor;
        node.location = current().index;
        mixin(tokenCheck!"static");
        return parseStaticCtorDtorCommon(node);
    }

    /**
     * Parses a StaticDestructor
     *
     * $(GRAMMAR $(RULEDEF staticDestructor):
     *     $(LITERAL 'static') $(LITERAL '~') $(LITERAL 'this') $(LITERAL '$(LPAREN)') $(LITERAL '$(RPAREN)') $(RULE memberFunctionAttribute)* ($(RULE functionBody) | $(LITERAL ";"))
     *     ;)
     */
    StaticDestructor parseStaticDestructor()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StaticDestructor;
        node.location = current().index;
        mixin(tokenCheck!"static");
        mixin(tokenCheck!"~");
        return parseStaticCtorDtorCommon(node);
    }

    /**
     * Parses an StaticIfCondition
     *
     * $(GRAMMAR $(RULEDEF staticIfCondition):
     *     $(LITERAL 'static') $(LITERAL 'if') $(LITERAL '$(LPAREN)') $(RULE assignExpression) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    StaticIfCondition parseStaticIfCondition()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin(simpleParse!(StaticIfCondition, tok!"static", tok!"if", tok!"(",
            "assignExpression|parseAssignExpression", tok!")"));
    }

    /**
     * Parses a StorageClass
     *
     * $(GRAMMAR $(RULEDEF storageClass):
     *       $(RULE alignAttribute)
     *     | $(RULE linkageAttribute)
     *     | $(RULE atAttribute)
     *     | $(RULE typeConstructor)
     *     | $(RULE deprecated)
     *     | $(LITERAL 'abstract')
     *     | $(LITERAL 'auto')
     *     | $(LITERAL 'enum')
     *     | $(LITERAL 'extern')
     *     | $(LITERAL 'final')
     *     | $(LITERAL 'nothrow')
     *     | $(LITERAL 'override')
     *     | $(LITERAL 'pure')
     *     | $(LITERAL 'ref')
     *     | $(LITERAL '___gshared')
     *     | $(LITERAL 'scope')
     *     | $(LITERAL 'static')
     *     | $(LITERAL 'synchronized')
     *     ;)
     */
    StorageClass parseStorageClass()
    {
        auto node = allocator.make!StorageClass;
        switch (current.type)
        {
        case tok!"@":
            mixin(parseNodeQ!(`node.atAttribute`, `AtAttribute`));
            break;
        case tok!"deprecated":
            mixin(parseNodeQ!(`node.deprecated_`, `Deprecated`));
            break;
        case tok!"align":
            mixin(parseNodeQ!(`node.alignAttribute`, `AlignAttribute`));
            break;
        case tok!"extern":
            if (peekIs(tok!"("))
            {
                mixin(parseNodeQ!(`node.linkageAttribute`, `LinkageAttribute`));
                break;
            }
            else goto case;
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
        case tok!"abstract":
        case tok!"auto":
        case tok!"enum":
        case tok!"final":
        case tok!"nothrow":
        case tok!"override":
        case tok!"pure":
        case tok!"ref":
        case tok!"__gshared":
        case tok!"scope":
        case tok!"static":
        case tok!"synchronized":
            node.token = advance();
            break;
        default:
            error(`Storage class expected`);
            return null;
        }
        return node;
    }

    /**
     * Parses a StructBody
     *
     * $(GRAMMAR $(RULEDEF structBody):
     *     $(LITERAL '{') $(RULE declaration)* $(LITERAL '}')
     *     ;)
     */
    StructBody parseStructBody()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StructBody;
        const start = expect(tok!"{");
        if (start !is null) node.startLocation = start.index;
        StackBuffer declarations;
        while (!currentIs(tok!"}") && moreTokens())
        {
            immutable c = allocator.setCheckpoint();
            if (!declarations.put(parseDeclaration(true, true)))
                allocator.rollback(c);
        }
        ownArray(node.declarations, declarations);
        const end = expect(tok!"}");
        if (end !is null) node.endLocation = end.index;
        return node;
    }

    /**
     * Parses a StructDeclaration
     *
     * $(GRAMMAR $(RULEDEF structDeclaration):
     *     $(LITERAL 'struct') $(LITERAL Identifier)? ($(RULE templateParameters) $(RULE constraint)? $(RULE structBody) | ($(RULE structBody) | $(LITERAL ';')))
     *     ;)
     */
    StructDeclaration parseStructDeclaration(Attribute[] attributes = null)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StructDeclaration;
        node.attributes = attributes;
        const t = expect(tok!"struct");
        if (currentIs(tok!"identifier"))
            node.name = advance();
        else
        {
            node.name.line = t.line;
            node.name.column = t.column;
        }
        node.comment = comment;
        comment = null;

        if (currentIs(tok!"("))
        {
            mixin(parseNodeQ!(`node.templateParameters`, `TemplateParameters`));
            if (currentIs(tok!"if"))
                mixin(parseNodeQ!(`node.constraint`, `Constraint`));
            mixin(parseNodeQ!(`node.structBody`, `StructBody`));
        }
        else if (currentIs(tok!"{"))
        {
            mixin(parseNodeQ!(`node.structBody`, `StructBody`));
        }
        else if (currentIs(tok!";"))
            advance();
        else
        {
            error("Template Parameters, Struct Body, or Semicolon expected");
            return null;
        }
        return node;
    }

    /**
     * Parses an StructInitializer
     *
     * $(GRAMMAR $(RULEDEF structInitializer):
     *     $(LITERAL '{') $(RULE structMemberInitializers)? $(LITERAL '}')
     *     ;)
     */
    StructInitializer parseStructInitializer()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StructInitializer;
        const a = expect(tok!"{");
        node.startLocation = a.index;
        if (currentIs(tok!"}"))
        {
            node.endLocation = current.index;
            advance();
        }
        else
        {
            mixin(parseNodeQ!(`node.structMemberInitializers`, `StructMemberInitializers`));
            const e = expect(tok!"}");
            mixin (nullCheck!`e`);
            node.endLocation = e.index;
        }
        return node;
    }

    /**
     * Parses a StructMemberInitializer
     *
     * $(GRAMMAR $(RULEDEF structMemberInitializer):
     *     ($(LITERAL Identifier) $(LITERAL ':'))? $(RULE nonVoidInitializer)
     *     ;)
     */
    StructMemberInitializer parseStructMemberInitializer()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StructMemberInitializer;
        if (startsWith(tok!"identifier", tok!":"))
        {
            node.identifier = tokens[index++];
            index++;
        }
        mixin(parseNodeQ!(`node.nonVoidInitializer`, `NonVoidInitializer`));
        return node;
    }

    /**
     * Parses StructMemberInitializers
     *
     * $(GRAMMAR $(RULEDEF structMemberInitializers):
     *     $(RULE structMemberInitializer) ($(LITERAL ',') $(RULE structMemberInitializer)?)*
     *     ;)
     */
    StructMemberInitializers parseStructMemberInitializers()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!StructMemberInitializers;
        StackBuffer structMemberInitializers;
        do
        {
            auto c = allocator.setCheckpoint();
            if (!structMemberInitializers.put(parseStructMemberInitializer()))
                allocator.rollback(c);
            if (currentIs(tok!","))
                advance();
            else
                break;
        } while (moreTokens() && !currentIs(tok!"}"));
        ownArray(node.structMemberInitializers, structMemberInitializers);
        return node;
    }

    /**
     * Parses a SwitchStatement
     *
     * $(GRAMMAR $(RULEDEF switchStatement):
     *     $(LITERAL 'switch') $(LITERAL '$(LPAREN)') $(RULE expression) $(LITERAL '$(RPAREN)') $(RULE statement)
     *     ;)
     */
    SwitchStatement parseSwitchStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!SwitchStatement;
        expect(tok!"switch");
        expect(tok!"(");
        mixin(parseNodeQ!(`node.expression`, `Expression`));
        expect(tok!")");
        mixin(parseNodeQ!(`node.statement`, `Statement`));
        return node;
    }

    /**
     * Parses a Symbol
     *
     * $(GRAMMAR $(RULEDEF symbol):
     *     $(LITERAL '.')? $(RULE identifierOrTemplateChain)
     *     ;)
     */
    Symbol parseSymbol()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Symbol;
        if (currentIs(tok!"."))
        {
            node.dot = true;
            advance();
        }
        mixin(parseNodeQ!(`node.identifierOrTemplateChain`, `IdentifierOrTemplateChain`));
        return node;
    }

    /**
     * Parses a SynchronizedStatement
     *
     * $(GRAMMAR $(RULEDEF synchronizedStatement):
     *     $(LITERAL 'synchronized') ($(LITERAL '$(LPAREN)') $(RULE expression) $(LITERAL '$(RPAREN)'))? $(RULE statementNoCaseNoDefault)
     *     ;)
     */
    SynchronizedStatement parseSynchronizedStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!SynchronizedStatement;
        expect(tok!"synchronized");
        if (currentIs(tok!"("))
        {
            expect(tok!"(");
            mixin(parseNodeQ!(`node.expression`, `Expression`));
            expect(tok!")");
        }
        mixin(parseNodeQ!(`node.statementNoCaseNoDefault`, `StatementNoCaseNoDefault`));
        return node;
    }

    /**
     * Parses a TemplateAliasParameter
     *
     * $(GRAMMAR $(RULEDEF templateAliasParameter):
     *     $(LITERAL 'alias') $(RULE type)? $(LITERAL Identifier) ($(LITERAL ':') ($(RULE type) | $(RULE assignExpression)))? ($(LITERAL '=') ($(RULE type) | $(RULE assignExpression)))?
     *     ;)
     */
    TemplateAliasParameter parseTemplateAliasParameter()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateAliasParameter;
        expect(tok!"alias");
        if (currentIs(tok!"identifier") && !peekIs(tok!"."))
        {
            if (peekIsOneOf(tok!",", tok!")", tok!"=", tok!":"))
                node.identifier = advance();
            else
                goto type;
        }
        else
        {
    type:
            mixin(parseNodeQ!(`node.type`, `Type`));
            const ident = expect(tok!"identifier");
            mixin(nullCheck!`ident`);
            node.identifier = *ident;
        }

        if (currentIs(tok!":"))
        {
            advance();
            if (isType())
                mixin(parseNodeQ!(`node.colonType`, `Type`));
            else
                mixin(parseNodeQ!(`node.colonExpression`, `AssignExpression`));
        }
        if (currentIs(tok!"="))
        {
            advance();
            if (isType())
                mixin(parseNodeQ!(`node.assignType`, `Type`));
            else
                mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        }
        return node;
    }

    /**
     * Parses a TemplateArgument
     *
     * $(GRAMMAR $(RULEDEF templateArgument):
     *       $(RULE type)
     *     | $(RULE assignExpression)
     *     ;)
     */
    TemplateArgument parseTemplateArgument()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (suppressedErrorCount > MAX_ERRORS) return null;
        auto node = allocator.make!TemplateArgument;
        immutable b = setBookmark();
        auto t = parseType();
        if (t !is null && currentIsOneOf(tok!",", tok!")"))
        {
            abandonBookmark(b);
            node.type = t;
        }
        else
        {
            goToBookmark(b);
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        }
        return node;
    }

    /**
     * Parses a TemplateArgumentList
     *
     * $(GRAMMAR $(RULEDEF templateArgumentList):
     *     $(RULE templateArgument) ($(LITERAL ',') $(RULE templateArgument)?)*
     *     ;)
     */
    TemplateArgumentList parseTemplateArgumentList()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseCommaSeparatedRule!(TemplateArgumentList, TemplateArgument)(true);
    }

    /**
     * Parses TemplateArguments
     *
     * $(GRAMMAR $(RULEDEF templateArguments):
     *     $(LITERAL '!') ($(LITERAL '$(LPAREN)') $(RULE templateArgumentList)? $(LITERAL '$(RPAREN)')) | $(RULE templateSingleArgument)
     *     ;)
     */
    TemplateArguments parseTemplateArguments()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (suppressedErrorCount > MAX_ERRORS) return null;
        auto node = allocator.make!TemplateArguments;
        expect(tok!"!");
        if (currentIs(tok!"("))
        {
            advance();
            if (!currentIs(tok!")"))
                mixin(parseNodeQ!(`node.templateArgumentList`, `TemplateArgumentList`));
             mixin(tokenCheck!")");
        }
        else
            mixin(parseNodeQ!(`node.templateSingleArgument`, `TemplateSingleArgument`));
        return node;
    }

    /**
     * Parses a TemplateDeclaration
     *
     * $(GRAMMAR $(RULEDEF templateDeclaration):
     *       $(LITERAL 'template') $(LITERAL Identifier) $(RULE templateParameters) $(RULE constraint)? $(LITERAL '{') $(RULE declaration)* $(LITERAL '}')
     *     ;)
     */
    TemplateDeclaration parseTemplateDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateDeclaration;
        node.comment = comment;
        comment = null;
        expect(tok!"template");
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.name = *ident;
        mixin(parseNodeQ!(`node.templateParameters`, `TemplateParameters`));
        if (currentIs(tok!"if"))
            mixin(parseNodeQ!(`node.constraint`, `Constraint`));
        const start = expect(tok!"{");
        mixin(nullCheck!`start`);
        node.startLocation = start.index;
        StackBuffer declarations;
        while (moreTokens() && !currentIs(tok!"}"))
        {
            immutable c = allocator.setCheckpoint();
            if (!declarations.put(parseDeclaration(true, true)))
                allocator.rollback(c);
        }
        ownArray(node.declarations, declarations);
        const end = expect(tok!"}");
        if (end !is null) node.endLocation = end.index;
        return node;
    }

    /**
     * Parses a TemplateInstance
     *
     * $(GRAMMAR $(RULEDEF templateInstance):
     *     $(LITERAL Identifier) $(RULE templateArguments)
     *     ;)
     */
    TemplateInstance parseTemplateInstance()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (suppressedErrorCount > MAX_ERRORS) return null;
        auto node = allocator.make!TemplateInstance;
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.identifier = *ident;
        mixin(parseNodeQ!(`node.templateArguments`, `TemplateArguments`));
        if (node.templateArguments is null)
            return null;
        return node;
    }

    /**
     * Parses a TemplateMixinExpression
     *
     * $(GRAMMAR $(RULEDEF templateMixinExpression):
     *     $(LITERAL 'mixin') $(RULE mixinTemplateName) $(RULE templateArguments)? $(LITERAL Identifier)?
     *     ;)
     */
    TemplateMixinExpression parseTemplateMixinExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateMixinExpression;
        mixin(tokenCheck!"mixin");
        mixin(parseNodeQ!(`node.mixinTemplateName`, `MixinTemplateName`));
        if (currentIs(tok!"!"))
            mixin(parseNodeQ!(`node.templateArguments`, `TemplateArguments`));
        if (currentIs(tok!"identifier"))
            node.identifier = advance();
        return node;
    }

    /**
     * Parses a TemplateParameter
     *
     * $(GRAMMAR $(RULEDEF templateParameter):
     *       $(RULE templateTypeParameter)
     *     | $(RULE templateValueParameter)
     *     | $(RULE templateAliasParameter)
     *     | $(RULE templateTupleParameter)
     *     | $(RULE templateThisParameter)
     *     ;)
     */
    TemplateParameter parseTemplateParameter()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateParameter;
        switch (current.type)
        {
        case tok!"alias":
            mixin(parseNodeQ!(`node.templateAliasParameter`, `TemplateAliasParameter`));
            break;
        case tok!"identifier":
            if (peekIs(tok!"..."))
                mixin(parseNodeQ!(`node.templateTupleParameter`, `TemplateTupleParameter`));
            else if (peekIsOneOf(tok!":", tok!"=", tok!",", tok!")"))
                mixin(parseNodeQ!(`node.templateTypeParameter`, `TemplateTypeParameter`));
            else
                mixin(parseNodeQ!(`node.templateValueParameter`, `TemplateValueParameter`));
            break;
        case tok!"this":
            mixin(parseNodeQ!(`node.templateThisParameter`, `TemplateThisParameter`));
            break;
        default:
            mixin(parseNodeQ!(`node.templateValueParameter`, `TemplateValueParameter`));
            break;
        }
        return node;
    }

    /**
     * Parses a TemplateParameterList
     *
     * $(GRAMMAR $(RULEDEF templateParameterList):
     *     $(RULE templateParameter) ($(LITERAL ',') $(RULE templateParameter)?)* $(LITERAL ',')?
     *     ;)
     */
    TemplateParameterList parseTemplateParameterList()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseCommaSeparatedRule!(TemplateParameterList, TemplateParameter)(true);
    }

    /**
     * Parses TemplateParameters
     *
     * $(GRAMMAR $(RULEDEF templateParameters):
     *     $(LITERAL '$(LPAREN)') $(RULE templateParameterList)? $(LITERAL '$(RPAREN)')
     *     ;)
     */
    TemplateParameters parseTemplateParameters()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateParameters;
        mixin(tokenCheck!"(");
        if (!currentIs(tok!")"))
            mixin(parseNodeQ!(`node.templateParameterList`, `TemplateParameterList`));
        mixin(tokenCheck!")");
        return node;
    }

    /**
     * Parses a TemplateSingleArgument
     *
     * $(GRAMMAR $(RULEDEF templateSingleArgument):
     *       $(RULE builtinType)
     *     | $(LITERAL Identifier)
     *     | $(LITERAL CharacterLiteral)
     *     | $(LITERAL StringLiteral)
     *     | $(LITERAL IntegerLiteral)
     *     | $(LITERAL FloatLiteral)
     *     | $(LITERAL '_true')
     *     | $(LITERAL '_false')
     *     | $(LITERAL '_null')
     *     | $(LITERAL 'this')
     *     | $(LITERAL '___DATE__')
     *     | $(LITERAL '___TIME__')
     *     | $(LITERAL '___TIMESTAMP__')
     *     | $(LITERAL '___VENDOR__')
     *     | $(LITERAL '___VERSION__')
     *     | $(LITERAL '___FILE__')
     *     | $(LITERAL '___LINE__')
     *     | $(LITERAL '___MODULE__')
     *     | $(LITERAL '___FUNCTION__')
     *     | $(LITERAL '___PRETTY_FUNCTION__')
     *     ;)
     */
    TemplateSingleArgument parseTemplateSingleArgument()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateSingleArgument;
        if (!moreTokens)
        {
            error("template argument expected instead of EOF");
            return null;
        }
        switch (current.type)
        {
        case tok!"this":
        case tok!"identifier":
		foreach (B; Literals) { case B: }
		foreach (C; BasicTypes) { case C: }
            node.token = advance();
            break;
        default:
            error(`Invalid template argument. (Try enclosing in parenthesis?)`);
            return null;
        }
        return node;
    }

    /**
     * Parses a TemplateThisParameter
     *
     * $(GRAMMAR $(RULEDEF templateThisParameter):
     *     $(LITERAL 'this') $(RULE templateTypeParameter)
     *     ;)
     */
    TemplateThisParameter parseTemplateThisParameter()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateThisParameter;
        expect(tok!"this");
        mixin(parseNodeQ!(`node.templateTypeParameter`, `TemplateTypeParameter`));
        return node;
    }

    /**
     * Parses an TemplateTupleParameter
     *
     * $(GRAMMAR $(RULEDEF templateTupleParameter):
     *     $(LITERAL Identifier) $(LITERAL '...')
     *     ;)
     */
    TemplateTupleParameter parseTemplateTupleParameter()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateTupleParameter;
        const i = expect(tok!"identifier");
        if (i is null)
            return null;
        node.identifier = *i;
        mixin(tokenCheck!"...");
        return node;
    }

    /**
     * Parses a TemplateTypeParameter
     *
     * $(GRAMMAR $(RULEDEF templateTypeParameter):
     *     $(LITERAL Identifier) ($(LITERAL ':') $(RULE type))? ($(LITERAL '=') $(RULE type))?
     *     ;)
     */
    TemplateTypeParameter parseTemplateTypeParameter()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateTypeParameter;
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.identifier = *ident;
        if (currentIs(tok!":"))
        {
            advance();
            mixin(parseNodeQ!(`node.colonType`, `Type`));
        }
        if (currentIs(tok!"="))
        {
            advance();
            mixin(parseNodeQ!(`node.assignType`, `Type`));
        }
        return node;
    }

    /**
     * Parses a TemplateValueParameter
     *
     * $(GRAMMAR $(RULEDEF templateValueParameter):
     *     $(RULE type) $(LITERAL Identifier) ($(LITERAL ':') $(RULE assignExpression))? $(RULE templateValueParameterDefault)?
     *     ;)
     */
    TemplateValueParameter parseTemplateValueParameter()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateValueParameter;
        mixin(parseNodeQ!(`node.type`, `Type`));
        mixin(tokenCheck!(`node.identifier`, "identifier"));
        if (currentIs(tok!":"))
        {
            advance();
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
        }
        if (currentIs(tok!"="))
            mixin(parseNodeQ!(`node.templateValueParameterDefault`, `TemplateValueParameterDefault`));
        return node;
    }

    /**
     * Parses a TemplateValueParameterDefault
     *
     * $(GRAMMAR $(RULEDEF templateValueParameterDefault):
     *     $(LITERAL '=') ($(LITERAL '___FILE__') | $(LITERAL '___MODULE__') | $(LITERAL '___LINE__') | $(LITERAL '___FUNCTION__') | $(LITERAL '___PRETTY_FUNCTION__') | $(RULE assignExpression))
     *     ;)
     */
    TemplateValueParameterDefault parseTemplateValueParameterDefault()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TemplateValueParameterDefault;
        expect(tok!"=");
        switch (current.type)
        {
        case tok!"__FILE__":
        case tok!"__MODULE__":
        case tok!"__LINE__":
        case tok!"__FUNCTION__":
        case tok!"__PRETTY_FUNCTION__":
            node.token = advance();
            break;
        default:
            mixin(parseNodeQ!(`node.assignExpression`, `AssignExpression`));
            break;
        }
        return node;
    }

    /**
     * Parses a TernaryExpression
     *
     * $(GRAMMAR $(RULEDEF ternaryExpression):
     *     $(RULE orOrExpression) ($(LITERAL '?') $(RULE expression) $(LITERAL ':') $(RULE ternaryExpression))?
     *     ;)
     */
    ExpressionNode parseTernaryExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));

        auto orOrExpression = parseOrOrExpression();
        if (orOrExpression is null)
            return null;
        if (currentIs(tok!"?"))
        {
            TernaryExpression node = allocator.make!TernaryExpression;
            node.orOrExpression = orOrExpression;
            advance();
            mixin(parseNodeQ!(`node.expression`, `Expression`));
            auto colon = expect(tok!":");
            mixin(nullCheck!`colon`);
            node.colon = *colon;
            mixin(parseNodeQ!(`node.ternaryExpression`, `TernaryExpression`));
            return node;
        }
        return orOrExpression;
    }

    /**
     * Parses a ThrowStatement
     *
     * $(GRAMMAR $(RULEDEF throwStatement):
     *     $(LITERAL 'throw') $(RULE expression) $(LITERAL ';')
     *     ;)
     */
    ThrowStatement parseThrowStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!ThrowStatement;
        expect(tok!"throw");
        mixin(parseNodeQ!(`node.expression`, `Expression`));
        expect(tok!";");
        return node;
    }

    /**
     * Parses an TraitsExpression
     *
     * $(GRAMMAR $(RULEDEF traitsExpression):
     *     $(LITERAL '___traits') $(LITERAL '$(LPAREN)') $(LITERAL Identifier) $(LITERAL ',') $(RULE TemplateArgumentList) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    TraitsExpression parseTraitsExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TraitsExpression;
        mixin(tokenCheck!"__traits");
        mixin(tokenCheck!"(");
        const ident = expect(tok!"identifier");
        mixin(nullCheck!`ident`);
        node.identifier = *ident;
        if (currentIs(tok!","))
        {
            advance();
            mixin (nullCheck!`(node.templateArgumentList = parseTemplateArgumentList())`);
        }
        mixin(tokenCheck!")");
        return node;
    }

    /**
     * Parses a TryStatement
     *
     * $(GRAMMAR $(RULEDEF tryStatement):
     *     $(LITERAL 'try') $(RULE declarationOrStatement) ($(RULE catches) | $(RULE catches) $(RULE finally) | $(RULE finally))
     *     ;)
     */
    TryStatement parseTryStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TryStatement;
        expect(tok!"try");
        mixin(parseNodeQ!(`node.declarationOrStatement`, `DeclarationOrStatement`));
        if (currentIs(tok!"catch"))
            mixin(parseNodeQ!(`node.catches`, `Catches`));
        if (currentIs(tok!"finally"))
            mixin(parseNodeQ!(`node.finally_`, `Finally`));
        return node;
    }

    /**
     * Parses a Type
     *
     * $(GRAMMAR $(RULEDEF type):
     *     $(RULE typeConstructors)? $(RULE type2) $(RULE typeSuffix)*
     *     ;)
     */
    Type parseType()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Type;
        if (!moreTokens)
        {
            error("type expected");
            return null;
        }
        switch (current.type)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
            if (!peekIs(tok!"("))
                mixin(parseNodeQ!(`node.typeConstructors`, `TypeConstructors`));
            break;
        default:
            break;
        }
        mixin(parseNodeQ!(`node.type2`, `Type2`));
        StackBuffer typeSuffixes;
        loop: while (moreTokens()) switch (current.type)
        {
        case tok!"[":
            // Allow this to fail because of the madness that is the
            // newExpression rule. Something starting with '[' may be arguments
            // to the newExpression instead of part of the type
            auto newBookmark = setBookmark();
            auto c = allocator.setCheckpoint();
            if (typeSuffixes.put(parseTypeSuffix()))
                abandonBookmark(newBookmark);
            else
            {
                allocator.rollback(c);
                goToBookmark(newBookmark);
                break loop;
            }
            break;
        case tok!"*":
        case tok!"delegate":
        case tok!"function":
            if (!typeSuffixes.put(parseTypeSuffix()))
                return null;
            break;
        default:
            break loop;
        }
        ownArray(node.typeSuffixes, typeSuffixes);
        return node;
    }

    /**
     * Parses a Type2
     *
     * $(GRAMMAR $(RULEDEF type2):
     *       $(RULE builtinType)
     *     | $(RULE symbol)
     *     | $(LITERAL 'super') $(LITERAL '.') $(RULE identifierOrTemplateChain)
     *     | $(LITERAL 'this') $(LITERAL '.') $(RULE identifierOrTemplateChain)
     *     | $(RULE typeofExpression) ($(LITERAL '.') $(RULE identifierOrTemplateChain))?
     *     | $(RULE typeConstructor) $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL '$(RPAREN)')
     *     | $(RULE vector)
     *     ;)
     */
    Type2 parseType2()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!Type2;
        if (!moreTokens)
        {
            error("type2 expected instead of EOF");
            return null;
        }
        switch (current.type)
        {
        case tok!"identifier":
        case tok!".":
            mixin(parseNodeQ!(`node.symbol`, `Symbol`));
            break;
        foreach (B; BasicTypes) { case B: }
            node.builtinType = parseBuiltinType();
            break;
        case tok!"super":
        case tok!"this":
            node.superOrThis = advance().type;
            mixin(tokenCheck!".");
            mixin(parseNodeQ!(`node.identifierOrTemplateChain`, `IdentifierOrTemplateChain`));
            break;
        case tok!"typeof":
            if ((node.typeofExpression = parseTypeofExpression()) is null)
                return null;
            if (currentIs(tok!"."))
            {
                advance();
                mixin(parseNodeQ!(`node.identifierOrTemplateChain`, `IdentifierOrTemplateChain`));
            }
            break;
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
            node.typeConstructor = advance().type;
            mixin(tokenCheck!"(");
            mixin (nullCheck!`(node.type = parseType())`);
            mixin(tokenCheck!")");
            break;
        case tok!"__vector":
            if ((node.vector = parseVector()) is null)
                return null;
            break;
        default:
            error("Basic type, type constructor, symbol, or typeof expected");
            return null;
        }
        return node;
    }

    /**
     * Parses a TypeConstructor
     *
     * $(GRAMMAR $(RULEDEF typeConstructor):
     *       $(LITERAL 'const')
     *     | $(LITERAL 'immutable')
     *     | $(LITERAL 'inout')
     *     | $(LITERAL 'shared')
     *     ;)
     */
    IdType parseTypeConstructor(bool validate = true)
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        switch (current.type)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
            if (!peekIs(tok!"("))
                return advance().type;
            goto default;
        default:
            if (validate)
                error(`"const", "immutable", "inout", or "shared" expected`);
            return tok!"";
        }
    }

    /**
     * Parses TypeConstructors
     *
     * $(GRAMMAR $(RULEDEF typeConstructors):
     *     $(RULE typeConstructor)+
     *     ;)
     */
    IdType[] parseTypeConstructors()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        IdType[] r;
        while (moreTokens())
        {
            IdType type = parseTypeConstructor(false);
            if (type == tok!"")
                break;
            else
                r ~= type;
        }
        return r;
    }

    /**
     * Parses a TypeSpecialization
     *
     * $(GRAMMAR $(RULEDEF typeSpecialization):
     *       $(RULE type)
     *     | $(LITERAL 'struct')
     *     | $(LITERAL 'union')
     *     | $(LITERAL 'class')
     *     | $(LITERAL 'interface')
     *     | $(LITERAL 'enum')
     *     | $(LITERAL 'function')
     *     | $(LITERAL 'delegate')
     *     | $(LITERAL 'super')
     *     | $(LITERAL 'const')
     *     | $(LITERAL 'immutable')
     *     | $(LITERAL 'inout')
     *     | $(LITERAL 'shared')
     *     | $(LITERAL 'return')
     *     | $(LITERAL 'typedef')
     *     | $(LITERAL '___parameters')
     *     ;)
     */
    TypeSpecialization parseTypeSpecialization()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TypeSpecialization;
        switch (current.type)
        {
        case tok!"struct":
        case tok!"union":
        case tok!"class":
        case tok!"interface":
        case tok!"enum":
        case tok!"function":
        case tok!"delegate":
        case tok!"super":
        case tok!"return":
        case tok!"typedef":
        case tok!"__parameters":
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
            if (peekIsOneOf(tok!")", tok!","))
            {
                node.token = advance();
                break;
            }
            goto default;
        default:
            mixin(parseNodeQ!(`node.type`, `Type`));
            break;
        }
        return node;
    }

    /**
     * Parses a TypeSuffix
     *
     * $(GRAMMAR $(RULEDEF typeSuffix):
     *       $(LITERAL '*')
     *     | $(LITERAL '[') $(RULE type)? $(LITERAL ']')
     *     | $(LITERAL '[') $(RULE assignExpression) $(LITERAL ']')
     *     | $(LITERAL '[') $(RULE assignExpression) $(LITERAL '..')  $(RULE assignExpression) $(LITERAL ']')
     *     | ($(LITERAL 'delegate') | $(LITERAL 'function')) $(RULE parameters) $(RULE memberFunctionAttribute)*
     *     ;)
     */
    TypeSuffix parseTypeSuffix()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TypeSuffix;
        switch (current.type)
        {
        case tok!"*":
            node.star = advance();
            return node;
        case tok!"[":
            node.array = true;
            advance();
            if (currentIs(tok!"]"))
            {
                advance();
                return node;
            }
            auto bookmark = setBookmark();
            auto type = parseType();
            if (type !is null && currentIs(tok!"]"))
            {
                abandonBookmark(bookmark);
                node.type = type;
            }
            else
            {
                goToBookmark(bookmark);
                mixin(parseNodeQ!(`node.low`, `AssignExpression`));
                mixin (nullCheck!`node.low`);
                if (currentIs(tok!".."))
                {
                    advance();
                    mixin(parseNodeQ!(`node.high`, `AssignExpression`));
                    mixin (nullCheck!`node.high`);
                }
            }
            mixin(tokenCheck!"]");
            return node;
        case tok!"delegate":
        case tok!"function":
            node.delegateOrFunction = advance();
            mixin(parseNodeQ!(`node.parameters`, `Parameters`));
            StackBuffer memberFunctionAttributes;
            while (currentIsMemberFunctionAttribute())
                if (!memberFunctionAttributes.put(parseMemberFunctionAttribute()))
                    return null;
            ownArray(node.memberFunctionAttributes, memberFunctionAttributes);
            return node;
        default:
            error(`"*", "[", "delegate", or "function" expected.`);
            return null;
        }
    }

    /**
     * Parses a TypeidExpression
     *
     * $(GRAMMAR $(RULEDEF typeidExpression):
     *     $(LITERAL 'typeid') $(LITERAL '$(LPAREN)') ($(RULE type) | $(RULE expression)) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    TypeidExpression parseTypeidExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TypeidExpression;
        expect(tok!"typeid");
        expect(tok!"(");
        immutable b = setBookmark();
        auto t = parseType();
        if (t is null || !currentIs(tok!")"))
        {
            goToBookmark(b);
            mixin(parseNodeQ!(`node.expression`, `Expression`));
            mixin (nullCheck!`node.expression`);
        }
        else
        {
            abandonBookmark(b);
            node.type = t;
        }
        expect(tok!")");
        return node;
    }

    /**
     * Parses a TypeofExpression
     *
     * $(GRAMMAR $(RULEDEF typeofExpression):
     *     $(LITERAL 'typeof') $(LITERAL '$(LPAREN)') ($(RULE expression) | $(LITERAL 'return')) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    TypeofExpression parseTypeofExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!TypeofExpression;
        expect(tok!"typeof");
        expect(tok!"(");
        if (currentIs(tok!"return"))
            node.return_ = advance();
        else
            mixin(parseNodeQ!(`node.expression`, `Expression`));
        expect(tok!")");
        return node;
    }

    /**
     * Parses a UnaryExpression
     *
     * $(GRAMMAR $(RULEDEF unaryExpression):
     *       $(RULE primaryExpression)
     *     | $(LITERAL '&') $(RULE unaryExpression)
     *     | $(LITERAL '!') $(RULE unaryExpression)
     *     | $(LITERAL '*') $(RULE unaryExpression)
     *     | $(LITERAL '+') $(RULE unaryExpression)
     *     | $(LITERAL '-') $(RULE unaryExpression)
     *     | $(LITERAL '~') $(RULE unaryExpression)
     *     | $(LITERAL '++') $(RULE unaryExpression)
     *     | $(LITERAL '--') $(RULE unaryExpression)
     *     | $(RULE newExpression)
     *     | $(RULE deleteExpression)
     *     | $(RULE castExpression)
     *     | $(RULE assertExpression)
     *     | $(RULE functionCallExpression)
     *     | $(RULE indexExpression)
     *     | $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL '$(RPAREN)') $(LITERAL '.') $(RULE identifierOrTemplateInstance)
     *     | $(RULE unaryExpression) $(LITERAL '.') $(RULE newExpression)
     *     | $(RULE unaryExpression) $(LITERAL '.') $(RULE identifierOrTemplateInstance)
     *     | $(RULE unaryExpression) $(LITERAL '--')
     *     | $(RULE unaryExpression) $(LITERAL '++')
     *     ;)
     */
    UnaryExpression parseUnaryExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (!moreTokens())
            return null;
        auto node = allocator.make!UnaryExpression;
        switch (current.type)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
            immutable b = setBookmark();
            if (peekIs(tok!"("))
            {
                advance();
                const past = peekPastParens();
                if (past !is null && past.type == tok!".")
                {
                    goToBookmark(b);
                    goto default;
                }
            }
            goToBookmark(b);
            goto case;
        case tok!"scope":
        case tok!"pure":
        case tok!"nothrow":
            mixin(parseNodeQ!(`node.functionCallExpression`, `FunctionCallExpression`));
            break;
        case tok!"&":
        case tok!"!":
        case tok!"*":
        case tok!"+":
        case tok!"-":
        case tok!"~":
        case tok!"++":
        case tok!"--":
            node.prefix = advance();
            mixin(parseNodeQ!(`node.unaryExpression`, `UnaryExpression`));
            break;
        case tok!"new":
            mixin(parseNodeQ!(`node.newExpression`, `NewExpression`));
            break;
        case tok!"delete":
            mixin(parseNodeQ!(`node.deleteExpression`, `DeleteExpression`));
            break;
        case tok!"cast":
            mixin(parseNodeQ!(`node.castExpression`, `CastExpression`));
            break;
        case tok!"assert":
            mixin(parseNodeQ!(`node.assertExpression`, `AssertExpression`));
            break;
        case tok!"(":
            // handle (type).identifier
            immutable b = setBookmark();
            skipParens();
            if (startsWith(tok!".", tok!"identifier"))
            {
                // go back to the (
                goToBookmark(b);
                immutable b2 = setBookmark();
                advance();
                auto t = parseType();
                if (t is null || !currentIs(tok!")"))
                {
                    goToBookmark(b);
                    goto default;
                }
                abandonBookmark(b2);
                node.type = t;
                advance(); // )
                advance(); // .
                mixin(parseNodeQ!(`node.identifierOrTemplateInstance`, `IdentifierOrTemplateInstance`));
                break;
            }
            else
            {
                // not (type).identifier, so treat as primary expression
                goToBookmark(b);
                goto default;
            }
        default:
            mixin(parseNodeQ!(`node.primaryExpression`, `PrimaryExpression`));
            break;
        }

        loop: while (moreTokens()) switch (current.type)
        {
        case tok!"!":
            if (peekIs(tok!"("))
            {
                index++;
                const p = peekPastParens();
                immutable bool jump =  (currentIs(tok!"(") && p !is null && p.type == tok!"(")
                    || peekIs(tok!"(");
                index--;
                if (jump)
                    goto case tok!"(";
                else
                    break loop;
            }
            else
                break loop;
        case tok!"(":
            auto newUnary = allocator.make!UnaryExpression();
            mixin (nullCheck!`newUnary.functionCallExpression = parseFunctionCallExpression(node)`);
            node = newUnary;
            break;
        case tok!"++":
        case tok!"--":
            auto n = allocator.make!UnaryExpression();
            n.unaryExpression = node;
            n.suffix = advance();
            node = n;
            break;
        case tok!"[":
            auto n = allocator.make!UnaryExpression;
            n.indexExpression = parseIndexExpression(node);
            node = n;
            break;
        case tok!".":
            advance();
            auto n = allocator.make!UnaryExpression();
            n.unaryExpression = node;
            if (currentIs(tok!"new"))
                mixin(parseNodeQ!(`node.newExpression`, `NewExpression`));
            else
                n.identifierOrTemplateInstance = parseIdentifierOrTemplateInstance();
            node = n;
            break;
        default:
            break loop;
        }
        return node;
    }

    /**
     * Parses an UnionDeclaration
     *
     * $(GRAMMAR $(RULEDEF unionDeclaration):
     *       $(LITERAL 'union') $(LITERAL Identifier) $(RULE templateParameters) $(RULE constraint)? $(RULE structBody)
     *     | $(LITERAL 'union') $(LITERAL Identifier) ($(RULE structBody) | $(LITERAL ';'))
     *     | $(LITERAL 'union') $(RULE structBody)
     *     ;)
     */
    UnionDeclaration parseUnionDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!UnionDeclaration;
        node.comment = comment;
        comment = null;
        // grab line number even if it's anonymous
        const t = expect(tok!"union");
        if (currentIs(tok!"identifier"))
        {
            node.name = advance();
            if (currentIs(tok!"("))
            {
                mixin(parseNodeQ!(`node.templateParameters`, `TemplateParameters`));
                if (currentIs(tok!"if"))
                    mixin(parseNodeQ!(`node.constraint`, `Constraint`));
                mixin(parseNodeQ!(`node.structBody`, `StructBody`));
            }
            else
                goto semiOrStructBody;
        }
        else
        {
            node.name.line = t.line;
            node.name.column = t.column;
    semiOrStructBody:
            if (currentIs(tok!";"))
                advance();
            else
                mixin(parseNodeQ!(`node.structBody`, `StructBody`));
        }
        return node;
    }

    /**
     * Parses a Unittest
     *
     * $(GRAMMAR $(RULEDEF unittest):
     *     $(LITERAL 'unittest') $(RULE blockStatement)
     *     ;)
     */
    Unittest parseUnittest()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin (simpleParse!(Unittest, tok!"unittest", "blockStatement|parseBlockStatement"));
    }

    /**
     * Parses a VariableDeclaration
     *
     * $(GRAMMAR $(RULEDEF variableDeclaration):
     *       $(RULE storageClass)* $(RULE type) $(RULE declarator) ($(LITERAL ',') $(RULE declarator))* $(LITERAL ';')
     *     | $(RULE storageClass)* $(RULE type) $(LITERAL identifier) $(LITERAL '=') $(RULE functionBody) $(LITERAL ';')
     *     | $(RULE autoDeclaration)
     *     ;)
     */
    VariableDeclaration parseVariableDeclaration(Type type = null, bool isAuto = false)
    {
        mixin (traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!VariableDeclaration;

        if (isAuto)
        {
            mixin(parseNodeQ!(`node.autoDeclaration`, `AutoDeclaration`));
            node.comment = node.autoDeclaration.comment;
            return node;
        }

        StackBuffer storageClasses;
        while (isStorageClass())
            if (!storageClasses.put(parseStorageClass()))
                return null;
        ownArray(node.storageClasses, storageClasses);

        node.type = type is null ? parseType() : type;
        node.comment = comment;
        comment = null;

        // TODO: handle function bodies correctly

        StackBuffer declarators;
        Declarator last;
        while (true)
        {
            auto declarator = parseDeclarator();
            if (!declarators.put(declarator))
                return null;
            else
                last = declarator;
            if (moreTokens() && currentIs(tok!","))
            {
                if (node.comment !is null)
                    declarator.comment = node.comment ~ "\n" ~ current.trailingComment;
                else
                    declarator.comment = current.trailingComment;
                advance();
            }
            else
                break;
        }
        ownArray(node.declarators, declarators);
        const semicolon = expect(tok!";");
        mixin (nullCheck!`semicolon`);
        if (node.comment !is null)
        {
            if (semicolon.trailingComment is null)
                last.comment = node.comment;
            else
                last.comment = node.comment ~ "\n" ~ semicolon.trailingComment;
        }
        else
            last.comment = semicolon.trailingComment;
        return node;
    }

    /**
     * Parses a Vector
     *
     * $(GRAMMAR $(RULEDEF vector):
     *     $(LITERAL '___vector') $(LITERAL '$(LPAREN)') $(RULE type) $(LITERAL '$(RPAREN)')
     *     ;)
     */
    Vector parseVector()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin (simpleParse!(Vector, tok!"__vector", tok!"(", "type|parseType", tok!")"));
    }

    /**
     * Parses a VersionCondition
     *
     * $(GRAMMAR $(RULEDEF versionCondition):
     *     $(LITERAL 'version') $(LITERAL '$(LPAREN)') ($(LITERAL IntegerLiteral) | $(LITERAL Identifier) | $(LITERAL 'unittest') | $(LITERAL 'assert')) $(LITERAL '$(RPAREN)')
     *     ;)
     */
	VersionCondition parseVersionCondition()
	{
		mixin(traceEnterAndExit!(__FUNCTION__));
		auto node = allocator.make!VersionCondition;
		const v = expect(tok!"version");
		mixin(nullCheck!`v`);
		node.versionIndex = v.index;
		mixin(tokenCheck!"(");
		if (currentIsOneOf(tok!"intLiteral", tok!"identifier", tok!"unittest", tok!"assert"))
			node.token = advance();
		else
		{
			error(`Expected an integer literal, an identifier, "assert", or "unittest"`);
			return null;
		}
		expect(tok!")");
		return node;
	}

    /**
     * Parses a VersionSpecification
     *
     * $(GRAMMAR $(RULEDEF versionSpecification):
     *     $(LITERAL 'version') $(LITERAL '=') ($(LITERAL Identifier) | $(LITERAL IntegerLiteral)) $(LITERAL ';')
     *     ;)
     */
    VersionSpecification parseVersionSpecification()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!VersionSpecification;
		mixin(tokenCheck!"version");
		mixin(tokenCheck!"=");
        if (!currentIsOneOf(tok!"identifier", tok!"intLiteral"))
        {
            error("Identifier or integer literal expected");
            return null;
        }
        node.token = advance();
        expect(tok!";");
        return node;
    }

    /**
     * Parses a WhileStatement
     *
     * $(GRAMMAR $(RULEDEF whileStatement):
     *     $(LITERAL 'while') $(LITERAL '$(LPAREN)') $(RULE expression) $(LITERAL '$(RPAREN)') $(RULE declarationOrStatement)
     *     ;)
     */
    WhileStatement parseWhileStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        auto node = allocator.make!WhileStatement;
		mixin(tokenCheck!"while");
        node.startIndex = current().index;
		mixin(tokenCheck!"(");
        mixin(parseNodeQ!(`node.expression`, `Expression`));
        mixin(tokenCheck!")");
        if (currentIs(tok!"}"))
        {
            error("Statement expected", false);
            return node; // this line makes DCD better
        }
        mixin(parseNodeQ!(`node.declarationOrStatement`, `DeclarationOrStatement`));
        return node;
    }

    /**
     * Parses a WithStatement
     *
     * $(GRAMMAR $(RULEDEF withStatement):
     *     $(LITERAL 'with') $(LITERAL '$(LPAREN)') $(RULE expression) $(LITERAL '$(RPAREN)') $(RULE statementNoCaseNoDefault)
     *     ;)
     */
    WithStatement parseWithStatement()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        mixin (simpleParse!(WithStatement, tok!"with", tok!"(",
            "expression|parseExpression", tok!")",
            "statementNoCaseNoDefault|parseStatementNoCaseNoDefault"));
    }

    /**
     * Parses an XorExpression
     *
     * $(GRAMMAR $(RULEDEF xorExpression):
     *       $(RULE andExpression)
     *     | $(RULE xorExpression) $(LITERAL '^') $(RULE andExpression)
     *     ;)
     */
    ExpressionNode parseXorExpression()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        return parseLeftAssocBinaryExpression!(XorExpression, AndExpression,
            tok!"^")();
    }

    /**
     * Current error count
     */
    uint errorCount;

    /**
     * Current warning count
     */
    uint warningCount;

    /**
     * Name used when reporting warnings and errors
     */
    string fileName;

    /**
     * Tokens to parse
     */
    const(Token)[] tokens;

    /**
     * Allocator used for creating AST nodes
     */
    RollbackAllocator* allocator;

    /**
     * Function that is called when a warning or error is encountered.
     * The parameters are the file name, line number, column number,
     * and the error or warning message.
     */
    void function(string, size_t, size_t, string, bool) messageFunction;

    void setTokens(const(Token)[] tokens)
    {
        this.tokens = tokens;
    }

    /**
     * Returns: true if there are more tokens
     */
    bool moreTokens() const nothrow pure @safe @nogc
    {
        return index < tokens.length;
    }

protected:

    uint suppressedErrorCount;

    enum MAX_ERRORS = 500;

    void ownArray(T)(ref T[] arr, ref StackBuffer sb)
    {
        if (sb.length == 0)
            return;
        void[] a = allocator.allocate(sb.length);
        a[] = sb[];
        arr = cast(T[]) a;
    }

    bool isCastQualifier() const
    {
        switch (current.type)
        {
        case tok!"const":
            if (peekIs(tok!")")) return true;
            return startsWith(tok!"const", tok!"shared", tok!")");
        case tok!"immutable":
            return peekIs(tok!")");
        case tok!"inout":
            if (peekIs(tok!")")) return true;
            return startsWith(tok!"inout", tok!"shared", tok!")");
        case tok!"shared":
            if (peekIs(tok!")")) return true;
            if (startsWith(tok!"shared", tok!"const", tok!")")) return true;
            return startsWith(tok!"shared", tok!"inout", tok!")");
        default:
            return false;
        }
    }

    bool isAssociativeArrayLiteral()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (auto p = current.index in cachedAAChecks)
            return *p;
        size_t currentIndex = current.index;
        immutable b = setBookmark();
        scope(exit) goToBookmark(b);
        advance();
        immutable bool result = !currentIs(tok!"]") && parseExpression() !is null && currentIs(tok!":");
        cachedAAChecks[currentIndex] = result;
        return result;
    }

    bool hasMagicDelimiter(alias L, alias T)()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        immutable i = index;
        scope(exit) index = i;
        assert (currentIs(L));
        advance();
        while (moreTokens()) switch (current.type)
        {
        case tok!"{": skipBraces(); break;
        case tok!"(": skipParens(); break;
        case tok!"[": skipBrackets(); break;
        case tok!"]": case tok!"}": return false;
        case T: return true;
        default: advance(); break;
        }
        return false;
    }

    enum DecType
    {
        autoVar,
        autoFun,
        other
    }

    DecType isAutoDeclaration(ref size_t beginIndex) nothrow @nogc @safe
    {
        immutable b = setBookmark();
        scope(exit) goToBookmark(b);

        loop: while (moreTokens()) switch (current().type)
        {
        case tok!"pragma":
            beginIndex = size_t.max;
            advance();
            if (currentIs(tok!"("))
            {
                skipParens();
                break;
            }
            else
                return DecType.other;
        case tok!"package":
        case tok!"private":
        case tok!"protected":
        case tok!"public":
            beginIndex = size_t.max;
            advance();
            break;
        case tok!"@":
            beginIndex = min(beginIndex, index);
            advance();
            if (currentIs(tok!"("))
                skipParens();
            else if (currentIs(tok!"identifier"))
            {
                advance();
                if (currentIs(tok!"!"))
                {
                    advance();
                    if (currentIs(tok!"("))
                        skipParens();
                    else
                        advance();
                }
                if (currentIs(tok!"("))
                    skipParens();
            }
            else
                return DecType.other;
            break;
        case tok!"deprecated":
        case tok!"align":
        case tok!"extern":
            beginIndex = min(beginIndex, index);
            advance();
            if (currentIs(tok!"("))
                skipParens();
            break;
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"synchronized":
            if (peekIs(tok!"("))
                return DecType.other;
            else
            {
                beginIndex = min(beginIndex, index);
                advance();
                break;
            }
        case tok!"auto":
        case tok!"enum":
        case tok!"export":
        case tok!"final":
        case tok!"__gshared":
        case tok!"nothrow":
        case tok!"override":
        case tok!"pure":
        case tok!"ref":
        case tok!"scope":
        case tok!"shared":
        case tok!"static":
            beginIndex = min(beginIndex, index);
            advance();
            break;
        default:
            break loop;
        }
        if (index <= b)
            return DecType.other;
        if (startsWith(tok!"identifier", tok!"="))
            return DecType.autoVar;
        if (startsWith(tok!"identifier", tok!"("))
        {
            advance();
            auto past = peekPastParens();
            if (past is null)
                return DecType.other;
            else if (past.type == tok!"=")
                return DecType.autoVar;
            else
                return DecType.autoFun;
        }
        return DecType.other;
    }

    bool isDeclaration()
    {
        mixin(traceEnterAndExit!(__FUNCTION__));
        if (!moreTokens()) return false;
        switch (current.type)
        {
        case tok!"final":
            return !peekIs(tok!"switch");
        case tok!"debug":
            if (peekIs(tok!":"))
                return true;
            goto case;
        case tok!"version":
            if (peekIs(tok!"="))
                return true;
            if (peekIs(tok!"("))
                goto default;
            return false;
        case tok!"synchronized":
            if (peekIs(tok!"("))
                return false;
            else
                goto default;
        case tok!"static":
            if (peekIs(tok!"if"))
                return false;
            goto case;
        case tok!"scope":
            if (peekIs(tok!"("))
                return false;
            goto case;
        case tok!"@":
        case tok!"abstract":
        case tok!"alias":
        case tok!"align":
        case tok!"auto":
        case tok!"class":
        case tok!"deprecated":
        case tok!"enum":
        case tok!"export":
        case tok!"extern":
        case tok!"__gshared":
        case tok!"interface":
        case tok!"nothrow":
        case tok!"override":
        case tok!"package":
        case tok!"private":
        case tok!"protected":
        case tok!"public":
        case tok!"pure":
        case tok!"ref":
        case tok!"struct":
        case tok!"union":
        case tok!"unittest":
            return true;
		foreach (B; BasicTypes) { case B: }
            return !peekIsOneOf(tok!".", tok!"(");
        case tok!"asm":
        case tok!"break":
        case tok!"case":
        case tok!"continue":
        case tok!"default":
        case tok!"do":
        case tok!"for":
        case tok!"foreach":
        case tok!"foreach_reverse":
        case tok!"goto":
        case tok!"if":
        case tok!"return":
        case tok!"switch":
        case tok!"throw":
        case tok!"try":
        case tok!"while":
        case tok!"{":
        case tok!"assert":
            return false;
        default:
            immutable b = setBookmark();
            scope(exit) goToBookmark(b);
            auto c = allocator.setCheckpoint();
            scope(exit) allocator.rollback(c);
            return parseDeclaration(true, true) !is null;
        }
    }

    /// Only use this in template parameter parsing
    bool isType()
    {
        if (!moreTokens()) return false;
        immutable b = setBookmark();
        scope (exit) goToBookmark(b);
        auto c = allocator.setCheckpoint();
        scope (exit) allocator.rollback(c);
        if (parseType() is null) return false;
        return currentIsOneOf(tok!",", tok!")", tok!"=");
    }

    bool isStorageClass()
    {
        if (!moreTokens()) return false;
        switch (current.type)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
            return !peekIs(tok!"(");
        case tok!"@":
        case tok!"deprecated":
        case tok!"abstract":
        case tok!"align":
        case tok!"auto":
        case tok!"enum":
        case tok!"extern":
        case tok!"final":
        case tok!"nothrow":
        case tok!"override":
        case tok!"pure":
        case tok!"ref":
        case tok!"__gshared":
        case tok!"scope":
        case tok!"static":
        case tok!"synchronized":
            return true;
        default:
            return false;
        }
    }

    bool isAttribute()
    {
        if (!moreTokens()) return false;
        switch (current.type)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"scope":
            return !peekIs(tok!"(");
        case tok!"static":
            return !peekIsOneOf(tok!"assert", tok!"this", tok!"if", tok!"~");
        case tok!"shared":
            return !(startsWith(tok!"shared", tok!"static", tok!"this")
                || startsWith(tok!"shared", tok!"static", tok!"~")
                || peekIs(tok!"("));
        case tok!"pragma":
            immutable b = setBookmark();
            scope(exit) goToBookmark(b);
            advance();
            const past = peekPastParens();
            if (past is null || *past == tok!";")
                return false;
            return true;
        case tok!"deprecated":
        case tok!"private":
        case tok!"package":
        case tok!"protected":
        case tok!"public":
        case tok!"export":
        case tok!"final":
        case tok!"synchronized":
        case tok!"override":
        case tok!"abstract":
        case tok!"auto":
        case tok!"__gshared":
        case tok!"pure":
        case tok!"nothrow":
        case tok!"@":
        case tok!"ref":
        case tok!"extern":
        case tok!"align":
            return true;
        default:
            return false;
        }
    }

    static bool isMemberFunctionAttribute(IdType t) pure nothrow @nogc @safe
    {
        switch (t)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
        case tok!"@":
        case tok!"pure":
        case tok!"nothrow":
        case tok!"return":
        case tok!"scope":
            return true;
        default:
            return false;
        }
    }

    static bool isTypeCtor(IdType t) pure nothrow @nogc @safe
    {
        switch (t)
        {
        case tok!"const":
        case tok!"immutable":
        case tok!"inout":
        case tok!"shared":
            return true;
        default:
            return false;
        }
    }

    bool currentIsMemberFunctionAttribute() const
    {
        return moreTokens && isMemberFunctionAttribute(current.type);
    }

    ExpressionNode parseLeftAssocBinaryExpression(alias ExpressionType,
        alias ExpressionPartType, Operators ...)(ExpressionNode part = null)
    {
        ExpressionNode node;
        mixin ("node = part is null ? parse" ~ ExpressionPartType.stringof ~ "() : part;");
        if (node is null)
            return null;
        while (currentIsOneOf(Operators))
        {
            auto n = allocator.make!ExpressionType;
            n.line = current.line;
            n.column = current.column;
            static if (__traits(hasMember, ExpressionType, "operator"))
                n.operator = advance().type;
            else
                advance();
            n.left = node;
            mixin (parseNodeQ!(`n.right`, ExpressionPartType.stringof));
            node = n;
        }
        return node;
    }

    ListType parseCommaSeparatedRule(alias ListType, alias ItemType,
            bool setLineAndColumn = false)(bool allowTrailingComma = false)
    {
        auto node = allocator.make!ListType;
        static if (setLineAndColumn)
        {
            node.line = current.line;
            node.column = current.column;
        }
        StackBuffer items;
        while (moreTokens())
        {
            if (!items.put(mixin("parse" ~ ItemType.stringof ~ "()")))
                return null;
            if (currentIs(tok!","))
            {
                advance();
                if (allowTrailingComma && currentIsOneOf(tok!")", tok!"}", tok!"]"))
                    break;
                else
                    continue;
            }
            else
                break;
        }
        ownArray(node.items, items);
        return node;
    }

    void warn(lazy string message)
    {
        import std.stdio : stderr;
        if (suppressMessages > 0)
            return;
        ++warningCount;
        auto column = index < tokens.length ? tokens[index].column : 0;
        auto line = index < tokens.length ? tokens[index].line : 0;
        if (messageFunction is null)
            stderr.writefln("%s(%d:%d)[warn]: %s", fileName, line, column, message);
        else
            messageFunction(fileName, line, column, message, false);
    }

    void error(string message, bool shouldAdvance = true)
    {
        import std.stdio : stderr;
        if (suppressMessages == 0)
        {
            ++errorCount;
            auto column = index < tokens.length ? tokens[index].column : tokens[$ - 1].column;
            auto line = index < tokens.length ? tokens[index].line : tokens[$ - 1].line;
            if (messageFunction is null)
                stderr.writefln("%s(%d:%d)[error]: %s", fileName, line, column, message);
            else
                messageFunction(fileName, line, column, message, true);
        }
        else
            ++suppressedErrorCount;
        while (shouldAdvance && moreTokens())
        {
            if (currentIsOneOf(tok!";", tok!"}",
                tok!")", tok!"]"))
            {
                advance();
                break;
            }
            else
                advance();
        }
    }

    void skip(alias O, alias C)()
    {
        assert (currentIs(O), current().text);
        advance();
        int depth = 1;
        while (moreTokens())
        {
            switch (tokens[index].type)
            {
                case C:
                    advance();
                    depth--;
                    if (depth <= 0)
                        return;
                    break;
                case O:
                    depth++;
                    advance();
                    break;
                default:
                    advance();
                    break;
            }
        }
    }

    void skipBraces() pure nothrow @safe @nogc
    {
        skip!(tok!"{", tok!"}")();
    }

    void skipParens() pure nothrow @safe @nogc
    {
        skip!(tok!"(", tok!")")();
    }

    void skipBrackets() pure nothrow @safe @nogc
    {
        skip!(tok!"[", tok!"]")();
    }

    const(Token)* peek() const pure nothrow @safe @nogc
    {
        return index + 1 < tokens.length ? &tokens[index + 1] : null;
    }

    const(Token)* peekPast(alias O, alias C)() const pure nothrow @safe @nogc
    {
        if (index >= tokens.length)
            return null;
        int depth = 1;
        size_t i = index;
        ++i;
        while (i < tokens.length)
        {
            if (tokens[i] == O)
            {
                ++depth;
                ++i;
            }
            else if (tokens[i] == C)
            {
                --depth;
                ++i;
                if (depth <= 0)
                    break;
            }
            else
                ++i;
        }
        return i >= tokens.length ? null : depth == 0 ? &tokens[i] : null;
    }

    const(Token)* peekPastParens() const pure nothrow @safe @nogc
    {
        return peekPast!(tok!"(", tok!")")();
    }

    const(Token)* peekPastBrackets() const pure nothrow @safe @nogc
    {
        return peekPast!(tok!"[", tok!"]")();
    }

    const(Token)* peekPastBraces() const pure nothrow @safe @nogc
    {
        return peekPast!(tok!"{", tok!"}")();
    }

    bool peekIs(IdType t) const pure nothrow @safe @nogc
    {
        return index + 1 < tokens.length && tokens[index + 1].type == t;
    }

    bool peekIsOneOf(IdType[] types...) const pure nothrow @safe @nogc
    {
        if (index + 1 >= tokens.length) return false;
        return canFind(types, tokens[index + 1].type);
    }

    /**
     * Returns a token of the specified type if it was the next token, otherwise
     * calls the error function and returns null. Advances the lexer by one token.
     */
    const(Token)* expect(IdType type)
    {
        if (index < tokens.length && tokens[index].type == type)
            return &tokens[index++];
        else
        {
            string tokenString = str(type) is null
                ? to!string(type) : str(type);
            immutable bool shouldNotAdvance = index < tokens.length
                && (tokens[index].type == tok!")"
                || tokens[index].type == tok!";"
                || tokens[index].type == tok!"}");
            auto token = (index < tokens.length
                ? (tokens[index].text is null ? str(tokens[index].type) : tokens[index].text)
                : "EOF");
            error("Expected " ~  tokenString ~ " instead of " ~ token,
                !shouldNotAdvance);
            return null;
        }
    }

    /**
     * Returns: the _current token
     */
    Token current() const pure nothrow @safe @nogc @property
    {
        return tokens[index];
    }

    /**
     * Returns: the _previous token
     */
    Token previous() const pure nothrow @safe @nogc @property
    {
        return tokens[index - 1];
    }

    /**
     * Advances to the next token and returns the current token
     */
    Token advance() pure nothrow @nogc @safe
    {
        return tokens[index++];
    }

    /**
     * Returns: true if the current token has the given type
     */
    bool currentIs(IdType type) const pure nothrow @safe @nogc
    {
        return index < tokens.length && tokens[index] == type;
    }

    /**
     * Returns: true if the current token is one of the given types
     */
    bool currentIsOneOf(IdType[] types...) const pure nothrow @safe @nogc
    {
        if (index >= tokens.length)
            return false;
        return canFind(types, current.type);
    }

    bool startsWith(IdType[] types...) const pure nothrow @safe @nogc
    {
        if (index + types.length >= tokens.length)
            return false;
        for (size_t i = 0; (i < types.length) && ((index + i) < tokens.length); ++i)
        {
            if (tokens[index + i].type != types[i])
                return false;
        }
        return true;
    }

    alias Bookmark = size_t;

    Bookmark setBookmark() pure nothrow @safe @nogc
    {
//        mixin(traceEnterAndExit!(__FUNCTION__));
        ++suppressMessages;
        return index;
    }

    void abandonBookmark(Bookmark) pure nothrow @safe @nogc
    {
        --suppressMessages;
        if (suppressMessages == 0)
            suppressedErrorCount = 0;
    }

    void goToBookmark(Bookmark bookmark) pure nothrow @safe @nogc
    {
        --suppressMessages;
        if (suppressMessages == 0)
            suppressedErrorCount = 0;
        index = bookmark;
    }

    template simpleParse(NodeType, parts ...)
    {
        static if (__traits(hasMember, NodeType, "comment"))
            enum nodeComm = "node.comment = comment;\n"
                        ~ "comment = null;\n";
        else enum nodeComm = "";

        static if (__traits(hasMember, NodeType, "line"))
            enum nodeLine = "node.line = current().line;\n";
        else enum nodeLine = "";

        static if (__traits(hasMember, NodeType, "column"))
            enum nodeColumn = "node.column = current().column;\n";
        else enum nodeColumn = "";

        static if (__traits(hasMember, NodeType, "location"))
            enum nodeLoc = "node.location = current().index;\n";
        else enum nodeLoc = "";

        enum simpleParse = "auto node = allocator.make!" ~ NodeType.stringof ~ ";\n"
                        ~ nodeComm ~ nodeLine ~ nodeColumn ~ nodeLoc
                        ~ simpleParseItems!(parts)
                        ~ "\nreturn node;\n";
    }

    template simpleParseItems(items ...)
    {
        static if (items.length > 1)
            enum simpleParseItems = simpleParseItem!(items[0]) ~ "\n"
                ~ simpleParseItems!(items[1 .. $]);
        else static if (items.length == 1)
            enum simpleParseItems = simpleParseItem!(items[0]);
        else
            enum simpleParseItems = "";
    }

    template simpleParseItem(alias item)
    {
        static if (is (typeof(item) == string))
            enum simpleParseItem = "if ((node." ~ item[0 .. item.countUntil("|")]
                ~ " = " ~ item[item.countUntil("|") + 1 .. $] ~ "()) is null) { return null; }";
        else
            enum simpleParseItem = "if (expect(" ~ item.stringof ~ ") is null) { return null; }";
    }

    template traceEnterAndExit(string fun)
    {
        enum traceEnterAndExit = `version (dparse_verbose) { _traceDepth++; trace("`
            ~ `\033[01;32m` ~ fun ~ `\033[0m"); }`
            ~ `version (dparse_verbose) scope(exit) { trace("`
            ~ `\033[01;31m` ~ fun ~ `\033[0m"); _traceDepth--; }`;
    }

    version (dparse_verbose)
    {
        import std.stdio : stderr;
        void trace(string message)
        {
            if (suppressMessages > 0)
                return;
            auto depth = format("%4d ", _traceDepth);
            if (index < tokens.length)
                stderr.writeln(depth, message, "(", current.line, ":", current.column, ")");
            else
                stderr.writeln(depth, message, "(EOF:0)");
        }
    }
    else
    {
        void trace(lazy string) {}
    }

    template parseNodeQ(string VarName, string NodeName)
    {
        enum parseNodeQ = `{ if ((` ~ VarName ~ ` = parse` ~ NodeName ~ `()) is null) return null; }`;
    }

    template nullCheck(string exp)
    {
        enum nullCheck = "{if ((" ~ exp ~ ") is null) { return null; }}";
    }

    template tokenCheck(string Tok)
    {
        enum tokenCheck = `{ if (expect(tok!"` ~ Tok ~ `") is null) { return null; } }`;
    }

    template tokenCheck(string Exp, string Tok)
    {
        enum tokenCheck = `{auto t = expect(tok!"` ~ Tok ~ `");`
            ~ `if (t is null) { return null;}`
            ~ `else {` ~ Exp ~ ` = *t; }}`;
    }

    T attachCommentFromSemicolon(T)(T node)
    {
        auto semicolon = expect(tok!";");
        if (semicolon is null)
            return null;
        if (semicolon.trailingComment !is null)
        {
            if (node.comment is null)
                node.comment = semicolon.trailingComment;
            else
            {
                node.comment ~= "\n";
                node.comment ~= semicolon.trailingComment;
            }
        }
        return node;
    }

    // This list MUST BE MAINTAINED IN SORTED ORDER.
    static immutable string[] REGISTER_NAMES = [
        "AH", "AL", "AX", "BH", "BL", "BP", "BPL", "BX", "CH", "CL", "CR0", "CR2",
        "CR3", "CR4", "CS", "CX", "DH", "DI", "DIL", "DL", "DR0", "DR1", "DR2",
        "DR3", "DR6", "DR7", "DS", "DX", "EAX", "EBP", "EBX", "ECX", "EDI", "EDX",
        "ES", "ESI", "ESP", "FS", "GS", "MM0", "MM1", "MM2", "MM3", "MM4", "MM5",
        "MM6", "MM7", "R10", "R10B", "R10D", "R10W", "R11", "R11B", "R11D", "R11W",
        "R12", "R12B", "R12D", "R12W", "R13", "R13B", "R13D", "R13W", "R14", "R14B",
        "R14D", "R14W", "R15", "R15B", "R15D", "R15W", "R8", "R8B", "R8D", "R8W",
        "R9", "R9B", "R9D", "R9W", "RAX", "RBP", "RBX", "RCX", "RDI", "RDX", "RSI",
        "RSP", "SI", "SIL", "SP", "SPL", "SS", "ST", "TR3", "TR4", "TR5", "TR6",
        "TR7", "XMM0", "XMM1", "XMM10", "XMM11", "XMM12", "XMM13", "XMM14", "XMM15",
        "XMM2", "XMM3", "XMM4", "XMM5", "XMM6", "XMM7", "XMM8", "XMM9", "YMM0",
        "YMM1", "YMM10", "YMM11", "YMM12", "YMM13", "YMM14", "YMM15", "YMM2",
        "YMM3", "YMM4", "YMM5", "YMM6", "YMM7", "YMM8", "YMM9"
    ];


    N parseStaticCtorDtorCommon(N)(N node)
    {
        node.line = current.line;
        node.column = current.column;
        mixin(tokenCheck!"this");
        mixin(tokenCheck!"(");
        mixin(tokenCheck!")");
        StackBuffer attributes;
        while (moreTokens() && !currentIsOneOf(tok!"{", tok!"in", tok!"out", tok!"body", tok!";"))
            if (!attributes.put(parseMemberFunctionAttribute()))
                return null;
        ownArray(node.memberFunctionAttributes, attributes);
        if (currentIs(tok!";"))
            advance();
        else
            mixin(parseNodeQ!(`node.functionBody`, `FunctionBody`));
        return node;
    }

    N parseInterfaceOrClass(N)(N node)
    {
        auto ident = expect(tok!"identifier");
        mixin (nullCheck!`ident`);
        node.name = *ident;
        node.comment = comment;
        comment = null;
        if (currentIs(tok!";"))
            goto emptyBody;
        if (currentIs(tok!"{"))
            goto structBody;
        if (currentIs(tok!"("))
        {
            mixin(parseNodeQ!(`node.templateParameters`, `TemplateParameters`));
            if (currentIs(tok!";"))
                goto emptyBody;
            constraint: if (currentIs(tok!"if"))
                mixin(parseNodeQ!(`node.constraint`, `Constraint`));
            if (node.baseClassList !is null)
            {
                if (currentIs(tok!"{"))
                    goto structBody;
                else if (currentIs(tok!";"))
                    goto emptyBody;
                else
                {
                    error("Struct body or ';' expected");
                    return null;
                }
            }
            if (currentIs(tok!":"))
                goto baseClassList;
            if (currentIs(tok!"if"))
                goto constraint;
            if (currentIs(tok!";"))
                goto emptyBody;
        }
        if (currentIs(tok!":"))
        {
    baseClassList:
            advance(); // :
            if ((node.baseClassList = parseBaseClassList()) is null)
                return null;
            if (currentIs(tok!"if"))
                goto constraint;
        }
    structBody:
        mixin(parseNodeQ!(`node.structBody`, `StructBody`));
        return node;
    emptyBody:
        advance();
        return node;
    }

    int suppressMessages;
    size_t index;
    int _traceDepth;
    string comment;
    bool[typeof(Token.index)] cachedAAChecks;
}
