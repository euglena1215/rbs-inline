module RBS
  module Inline
    module AST
      module Members
        class Base
        end

        class RubyDef < Base
          attr_reader :node #:: Prism::DefNode
          attr_reader :comments #:: AnnotationParser::ParsingResult?

          # The visibility directly attached to the `def` node
          #
          # `nil` when the `def` node is not passed to `private`/`public` calls.
          #
          # ```rb
          # def foo() end            # <= nil
          # private def foo() end    # <= :private
          # ```
          attr_reader :visibility #:: RBS::AST::Members::visibility?

          # @rbs node: Prism::DefNode
          # @rbs comments: AnnotationParser::ParsingResult?
          # @rbs visibility: RBS::AST::Members::visibility?
          # @rbs return: void
          def initialize(node, comments, visibility)
            @node = node
            @comments = comments
            @visibility = visibility
          end

          # @rbs return: Symbol -- the name of the method
          def method_name
            node.name
          end

          # @rbs return: Array[Annotations::Assertion]
          def method_type_annotations
            if comments
              comments.annotations.select do |annotation|
                annotation.is_a?(Annotations::Assertion) && annotation.type.is_a?(MethodType)
              end #: Array[Annotations::Assertion]
            else
              []
            end
          end

          # Returns the `kind` of the method definition
          #
          # [FIXME] It only supports `self` receiver.
          #
          # ```rb
          # def self.foo = ()    # :sigleton
          # def object.foo = ()  # Not supported (returns :instance)
          # ```
          #
          # @rbs return: RBS::AST::Members::MethodDefinition::kind
          def method_kind
            # FIXME: really hacky implementation
            case node.receiver
            when Prism::SelfNode
              :singleton
            when nil
              :instance
            else
              :instance
            end
          end

          # @rbs return: Types::t?
          def return_type
            if comments
              annot = comments.annotations.find {|annot| annot.is_a?(Annotations::ReturnType ) } #: Annotations::ReturnType?
              if annot
                annot.type
              end
            end
          end

          # @rbs return: Hash[Symbol, Types::t?]
          def var_type_hash
            types = {} #: Hash[Symbol, Types::t?]

            if comments
              comments.annotations.each do |annotation|
                if annotation.is_a?(Annotations::VarType)
                  name = annotation.name
                  type = annotation.type

                  if name
                    types[name] = type
                  end
                end
              end
            end

            types
          end

          # @rbs return: Array[RBS::AST::Members::MethodDefinition::Overload]
          def method_overloads
            if !(annots = method_type_annotations).empty?
              annots.map do
                method_type = _1.type #: MethodType

                RBS::AST::Members::MethodDefinition::Overload.new(
                  method_type: method_type,
                  annotations: []
                )
              end
            else
              required_positionals = [] #: Array[Types::Function::Param]
              optional_positionals = [] #: Array[Types::Function::Param]
              rest_positionals = nil #: Types::Function::Param?
              required_keywords = {} #: Hash[Symbol, Types::Function::Param]
              optional_keywords = {} #: Hash[Symbol, Types::Function::Param]
              rest_keywords = nil #: Types::Function::Param?

              if node.parameters
                node.parameters.requireds.each do |param|
                  case param
                  when Prism::RequiredParameterNode
                    required_positionals << Types::Function::Param.new(
                      name: param.name,
                      type: var_type_hash[param.name] || Types::Bases::Any.new(location: nil),
                      location: nil
                    )
                  end
                end

                node.parameters.optionals.each do |param|
                  case param
                  when Prism::OptionalParameterNode
                    optional_positionals << Types::Function::Param.new(
                      name: param.name,
                      type: var_type_hash[param.name] || Types::Bases::Any.new(location: nil),
                      location: nil
                    )
                  end
                end

                if (rest = node.parameters.rest).is_a?(Prism::RestParameterNode)
                  rest_type =
                    if rest.name
                      var_type_hash[rest.name]
                    end

                  if rest_type
                    if rest_type.is_a?(Types::ClassInstance)
                      if rest_type.name.name == :Array && rest_type.name.namespace.empty?
                        rest_type = rest_type.args[0]
                      end
                    end
                  end

                  rest_positionals = Types::Function::Param.new(
                    name: rest.name,
                    type: rest_type || Types::Bases::Any.new(location: nil),
                    location: nil
                  )
                end

                node.parameters.keywords.each do |node|
                  if node.is_a?(Prism::RequiredKeywordParameterNode)
                    required_keywords[node.name] = Types::Function::Param.new(
                      name: nil,
                      type: var_type_hash[node.name] || Types::Bases::Any.new(location: nil),
                      location: nil
                    )
                  end

                  if node.is_a?(Prism::OptionalKeywordParameterNode)
                    optional_keywords[node.name] = Types::Function::Param.new(
                      name: nil,
                      type: var_type_hash[node.name] || Types::Bases::Any.new(location: nil),
                      location: nil
                    )
                  end
                end

                if (kw_rest = node.parameters.keyword_rest).is_a?(Prism::KeywordRestParameterNode)
                  rest_type =
                    if kw_rest.name
                      var_type_hash[kw_rest.name]
                    end

                  if rest_type
                    if rest_type.is_a?(Types::ClassInstance)
                      if rest_type.name.name == :Hash && rest_type.name.namespace.empty?
                        rest_type = rest_type.args[1]
                      end
                    end
                  end

                  rest_keywords = Types::Function::Param.new(
                    name: kw_rest.name,
                    type: rest_type || Types::Bases::Any.new(location: nil),
                    location: nil)
                end

                if node.parameters.block
                  if block_name = node.parameters.block.name
                    var_type = var_type_hash[block_name]

                    if var_type.is_a?(Types::Optional)
                      optional = true
                      var_type = var_type.type
                    else
                      optional = false
                    end

                    if var_type.is_a?(Types::Proc)
                      block = Types::Block.new(type: var_type.type, self_type: var_type.self_type, required: !optional)
                    end
                  end
                end
              end

              [
                RBS::AST::Members::MethodDefinition::Overload.new(
                  method_type: RBS::MethodType.new(
                    type_params: [],
                    type: Types::Function.new(
                      required_positionals: required_positionals,
                      optional_positionals: optional_positionals,
                      rest_positionals: rest_positionals,
                      trailing_positionals: [],
                      required_keywords: required_keywords,
                      optional_keywords: optional_keywords,
                      rest_keywords: rest_keywords,
                      return_type: return_type || Types::Bases::Any.new(location: nil)
                    ),
                    block: block,
                    location: nil
                  ),
                  annotations: []
                )
              ]
            end
          end

          # @rbs return: Array[RBS::AST::Annotation]
          def method_annotations
            if comments
              comments.annotations.flat_map do |annotation|
                if annotation.is_a?(AST::Annotations::RBSAnnotation)
                  annotation.contents.map do |string|
                    RBS::AST::Annotation.new(
                      string: string[3...-1] || "",
                      location: nil
                    )
                  end
                else
                  []
                end
              end
            else
              []
            end
          end
        end

        class RubyAlias < Base
          attr_reader :node #:: Prism::AliasMethodNode

          attr_reader :comments #:: AnnotationParser::ParsingResult?

          # @rbs node: Prism::AliasMethodNode
          # @rbs comments: AnnotationParser::ParsingResult?
          def initialize(node, comments)
            @node = node
            @comments = comments
          end

          # @rbs return: Symbol -- the name of *old* method
          def old_name
            raise unless node.old_name.is_a?(Prism::SymbolNode)
            value = node.old_name.value or raise
            value.to_sym
          end

          # @rbs return: Symbol -- the name of *new* method
          def new_name
            raise unless node.new_name.is_a?(Prism::SymbolNode)
            value = node.new_name.value or raise
            value.to_sym
          end
        end

        class RubyMixin < Base
          # CallNode that calls `include`, `prepend`, and `extend` method
          attr_reader :node #:: Prism::CallNode

          # Comments attached to the call node
          attr_reader :comments #:: AnnotationParser::ParsingResult?

          # Possible following type application annotation
          attr_reader :application #:: Annotations::Application?

          # @rbs node: Prism::CallNode
          # @rbs comments: AnnotationParser::ParsingResult?
          # @rbs application: Annotations::Application?
          # @rbs return: void
          def initialize(node, comments, application)
            @node = node
            @comments = comments
            @application = application
          end

          # @rbs return: ::RBS::AST::Members::Include
          #            | ::RBS::AST::Members::Extend
          #            | ::RBS::AST::Members::Prepend
          #            | nil
          def rbs
            return unless node.arguments
            return unless node.arguments.arguments.size == 1

            arg = node.arguments.arguments[0] || raise
            if arg.is_a?(Prism::ConstantReadNode)
              type_name = RBS::TypeName.new(name: arg.name, namespace: RBS::Namespace.empty)
            else
              raise
            end

            args = [] #: Array[Types::t]
            if application
              if application.types
                args.concat(application.types)
              end
            end

            case node.name
            when :include
              RBS::AST::Members::Include.new(
                name: type_name,
                args: args,
                annotations: [],
                location: nil,
                comment: nil
              )
            when :extend
              RBS::AST::Members::Extend.new(
                name: type_name,
                args: args,
                annotations: [],
                location: nil,
                comment: nil
              )
            when :prepend
              RBS::AST::Members::Prepend.new(
                name: type_name,
                args: args,
                annotations: [],
                location: nil,
                comment: nil
              )
            end
          end
        end

        class RubyAttr < Base
          attr_reader :node #:: Prism::CallNode
          attr_reader :comments #:: AnnotationParser::ParsingResult?
          attr_reader :assertion #:: Annotations::Assertion?

          # @rbs node: Prism::CallNode
          # @rbs comments: AnnotationParser::ParsingResult?
          # @rbs assertion: Annotations::Assertion?
          # @rbs return: void
          def initialize(node, comments, assertion)
            @node = node
            @comments = comments
            @assertion = assertion
          end

          # @rbs return Array[RBS::AST::Members::AttrReader | RBS::AST::Members::AttrWriter | RBS::AST::Members::AttrAccessor]?
          def rbs
            if comments
              comment = RBS::AST::Comment.new(string: comments.content, location: nil)
            end

            klass =
              case node.name
              when :attr_reader
                RBS::AST::Members::AttrReader
              when :attr_writer
                RBS::AST::Members::AttrWriter
              when :attr_accessor
                RBS::AST::Members::AttrAccessor
              else
                raise
              end

            args = [] #: Array[Symbol]
            if node.arguments
              node.arguments.arguments.each do |arg|
                if arg.is_a?(Prism::SymbolNode)
                  value = arg.value or raise
                  args << value.to_sym
                end
              end
            end

            unless args.empty?
              args.map do |arg|
                klass.new(
                  name: arg,
                  type: attribute_type,
                  ivar_name: nil,
                  kind: :instance,
                  annotations: [],
                  location: nil,
                  comment: comment,
                  visibility: nil
                )
              end
            end
          end

          # Returns the type of the attribute
          #
          # Returns `untyped` when not annotated.
          #
          # @rbs return: Types::t
          def attribute_type
            type = assertion&.type
            raise if type.is_a?(MethodType)

            type || Types::Bases::Any.new(location: nil)
          end
        end

        # `private` call without arguments
        #
        class RubyPrivate < Base
          attr_reader :node #:: Prism::CallNode

          # @rbs node: Prism::CallNode
          def initialize(node)
            @node = node
          end
        end

        # `public` call without arguments
        #
        class RubyPublic < Base
          attr_reader :node #:: Prism::CallNode

          # @rbs node: Prism::CallNode
          def initialize(node)
            @node = node
          end
        end
      end
    end
  end
end
