require_relative 'node'

module Bpl
  module AST
    class Declaration < Node
    end
    
    class TypeDeclaration < Declaration
      children :name, :arguments
      children :finite, :type
      def signature; "type #{@name}" end
      def print(&blk)
        args = @arguments.map{|a| yield a} * " "
        type = @type ? " = #{yield @type}" : ""
        "type #{print_attrs(&blk)} #{'finite' if @finite} #{@name} #{args} #{type};".fmt
      end
    end
    
    class FunctionDeclaration < Declaration
      children :name, :type_arguments, :arguments, :return, :body
      def signature
        args = @arguments.map(&:flatten).flatten.map{|x|x.type} * ","
        "#{@name}(#{args}): #{@return.type}".gsub(/\s/,'')
      end
      def print(&blk)
        args = @arguments.map{|a| yield a} * ", "
        ret = yield @return
        body = @body ? " { #{yield @body} }" : ";"
        "function #{print_attrs(&blk)} #{@name}(#{args}) returns (#{ret})#{body}".fmt
      end
    end
    
    class AxiomDeclaration < Declaration
      children :expression
      def print(&blk) "axiom #{print_attrs(&blk)} #{yield @expression};".fmt end
    end
    
    class NameDeclaration < Declaration
      children :names, :type, :where
      def signature; "#{@names * ", "}: #{@type}" end      
      def print(&blk)
        names = @names.empty? ? "" : (@names * ", " + ":")
        where = @where ? "where #{@where}" : ""
        "#{print_attrs(&blk)} #{names} #{yield @type} #{where}".fmt
      end
      def flatten
        if @names.empty?
          self
        else
          @names.map do |name|
            self.class.new(names: [name], type: @type, where: @where)
          end
        end
      end
      def idents
        @names.map do |name|
          Identifier.new name: name, kind: :storage, declaration: self
        end
      end
    end
    
    class VariableDeclaration < NameDeclaration
      def signature; "var #{@names * ", "}: #{@type}" end
      def print; "var #{super};" end
    end
    
    class ConstantDeclaration < NameDeclaration
      children :unique, :order_spec
      def signature; "const #{@names * ", "}: #{@type}" end
      def print(&blk)
        names = @names.empty? ? "" : (@names * ", " + ":")
        ord = ""
        if @order_spec && @order_spec[0]
          ord << ' <: '
          unless @order_spec[0].empty?
            ord << @order_spec[0].map{|c,p| (c ? 'unique ' : '') + p.to_s } * ", " 
          end
        end
        ord << ' complete' if @order_spec && @order_spec[1]
        "const #{print_attrs(&blk)} #{'unique' if @unique} #{names} #{yield @type}#{ord};".fmt
      end
    end
    
    class ProcedureDeclaration < Declaration
      children :name, :type_arguments, :parameters, :returns
      children :specifications, :body
      def modifies
        specifications.map{|s| s.is_a?(ModifiesClause) ? s.identifiers : []}.flatten
      end
      def fresh_var(type)
        return nil unless @body
        taken = @body.declarations.map{|d| d.names}.flatten
        var = (0..Float::INFINITY).each{|i| unless taken.include?(v = "_#{i}"); break v end}
        @body.declarations << decl = VariableDeclaration.new(names: [var], type: type)
        decl
      end
      def sig(&blk)
        params = @parameters.map{|a| yield a} * ", "
        rets = @returns.empty? ? "" : "returns (#{@returns.map{|a| yield a} * ", "})"
        "#{print_attrs(&blk)} #{@name}(#{params}) #{rets}".fmt
      end
      def signature
        "#{@name}(#{@parameters.map(&:type) * ","})" +
        (@returns.empty? ? "" : ":#{@returns.map(&:type) * ","}")
      end
      def print(&block)
        specs = @specifications.empty? ? "" : "\n"
        specs << @specifications.map{|a| yield a} * "\n"
        if @body
          "procedure #{sig(&block)}#{specs}\n#{yield @body}"
        else
          "procedure #{sig(&block)};#{specs}"
        end
      end
    end
    
    class ImplementationDeclaration < ProcedureDeclaration
      def print; "implementation #{sig(&block)}\n#{yield @body}" end
    end
  end
end