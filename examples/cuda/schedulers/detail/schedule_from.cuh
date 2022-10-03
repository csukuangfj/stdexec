/*
 * Copyright (c) NVIDIA
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <execution.hpp>
#include <type_traits>

#include "common.cuh"
#include "tuple.cuh"
#include "variant.cuh"

namespace example::cuda::stream {

namespace schedule_from {

  template <class SenderId, class ReceiverId>
    struct receiver_t : receiver_base_t {
      using Sender = std::__t<SenderId>;
      using Receiver = std::__t<ReceiverId>;

      template <class... _Ts>
        using variant =
          std::__minvoke<
            std::__if_c<
              sizeof...(_Ts) != 0,
              std::__transform<std::__q1<std::decay_t>, std::__munique<std::__q<variant_t>>>,
              std::__mconst<std::execution::__not_a_variant>>,
            _Ts...>;

      template <class... _Ts>
        using bind_tuples =
          std::__mbind_front_q<
            variant,
            tuple_t<std::execution::set_stopped_t>,
            _Ts...>;

      using bound_values_t =
        std::execution::__value_types_of_t<
          Sender,
          std::execution::env_of_t<Receiver>,
          std::__mbind_front_q<decayed_tuple, std::execution::set_value_t>,
          std::__q<bind_tuples>>;

      using storage_t =
        std::execution::__error_types_of_t<
          Sender,
          std::execution::env_of_t<Receiver>,
          std::__transform<
            // std::__mbind_front<std::__replace<std::exception_ptr, cudaError_t, std::__q<decayed_tuple>>, std::execution::set_error_t>,
            std::__mbind_front_q<decayed_tuple, std::execution::set_error_t>,
            bound_values_t>>;

      constexpr static std::size_t memory_allocation_size = sizeof(storage_t);

      operation_state_base_t<ReceiverId>& operation_state_;

      template <std::__one_of<std::execution::set_value_t,
                              std::execution::set_error_t,
                              std::execution::set_stopped_t> Tag,
                class... As  _NVCXX_CAPTURE_PACK(As)>
      friend void tag_invoke(Tag tag, receiver_t&& self, As&&... as) noexcept {
        auto stream = self.operation_state_.stream_;
        _NVCXX_EXPAND_PACK(As, as,
          storage_t *storage = reinterpret_cast<storage_t*>(self.operation_state_.temp_storage_);
          storage->template emplace<decayed_tuple<Tag, As...>>(Tag{}, (As&&)as...);

          visit([&](auto& tpl) {
            apply([&](auto tag, auto&&... tas) {
              self.operation_state_.template propagate_completion_signal(
                  tag, (std::decay_t<decltype(tas)>&)tas...);
            }, tpl);
          }, *storage);
        );
      }

      friend std::execution::env_of_t<std::__t<ReceiverId>>
      tag_invoke(std::execution::get_env_t, const receiver_t& self) {
        return std::execution::get_env(self.operation_state_.receiver_);
      }
    };

  template <class Sender>
    struct source_sender_t : sender_base_t {
      template <std::__decays_to<source_sender_t> Self, std::execution::receiver Receiver>
      friend auto tag_invoke(std::execution::connect_t, Self&& self, Receiver&& rcvr)
        -> std::execution::connect_result_t<std::__member_t<Self, Sender>, Receiver> {
          return std::execution::connect(((Self&&)self).sender_, (Receiver&&)rcvr);
        }

      template <std::execution::tag_category<std::execution::forwarding_sender_query> _Tag, class... _As _NVCXX_CAPTURE_PACK(_As)>
        requires std::__callable<_Tag, const Sender&, _As...>
      friend auto tag_invoke(_Tag __tag, const source_sender_t& __self, _As&&... __as)
        noexcept(std::__nothrow_callable<_Tag, const Sender&, _As...>)
        -> std::__call_result_if_t<std::execution::tag_category<_Tag, std::execution::forwarding_sender_query>, _Tag, const Sender&, _As...> {
        _NVCXX_EXPAND_PACK_RETURN(_As, _as,
          return ((_Tag&&) __tag)(__self.sender_, (_As&&) __as...);
        )
      }

      template <std::__decays_to<source_sender_t> _Self, class _Env>
        friend auto tag_invoke(std::execution::get_completion_signatures_t, _Self&&, _Env) ->
          std::execution::make_completion_signatures<
            std::__member_t<_Self, Sender>,
            _Env>;

      Sender sender_;
    };
}

template <class Scheduler, class SenderId>
  struct schedule_from_sender_t : gpu_sender_base_t {
    using Sender = std::__t<SenderId>;
    using source_sender_th = schedule_from::source_sender_t<Sender>;

    detail::queue::task_hub_t* hub_;
    source_sender_th sndr_;

    template <class Self, class Receiver>
      using receiver_t = schedule_from::receiver_t<
        std::__x<std::__member_t<Self, Sender>>, 
        std::__x<Receiver>>;

    template <std::__decays_to<schedule_from_sender_t> Self, std::execution::receiver Receiver>
      requires std::execution::sender_to<std::__member_t<Self, source_sender_th>, Receiver>
    friend auto tag_invoke(std::execution::connect_t, Self&& self, Receiver&& rcvr)
      -> stream_op_state_t<std::__member_t<Self, source_sender_th>, receiver_t<Self, Receiver>, Receiver> {
        return stream_op_state<std::__member_t<Self, source_sender_th>>(
            self.hub_,
            ((Self&&)self).sndr_,
            (Receiver&&)rcvr,
            [&](operation_state_base_t<std::__x<Receiver>>& stream_provider) -> receiver_t<Self, Receiver> {
              return receiver_t<Self, Receiver>{{}, stream_provider};
            });
    }

    template <std::__one_of<std::execution::set_value_t, std::execution::set_stopped_t> _Tag>
    friend Scheduler tag_invoke(std::execution::get_completion_scheduler_t<_Tag>, const schedule_from_sender_t& __self) noexcept {
      return {__self.hub_};
    }

    template <std::execution::tag_category<std::execution::forwarding_sender_query> _Tag, class... _As _NVCXX_CAPTURE_PACK(_As)>
      requires std::__callable<_Tag, const Sender&, _As...>
    friend auto tag_invoke(_Tag __tag, const schedule_from_sender_t& __self, _As&&... __as)
      noexcept(std::__nothrow_callable<_Tag, const Sender&, _As...>)
      -> std::__call_result_if_t<std::execution::tag_category<_Tag, std::execution::forwarding_sender_query>, _Tag, const Sender&, _As...> {
      _NVCXX_EXPAND_PACK_RETURN(_As, _as,
        return ((_Tag&&) __tag)(__self.sndr_, (_As&&) __as...);
      )
    }

    template <std::__decays_to<schedule_from_sender_t> _Self, class _Env>
      friend auto tag_invoke(std::execution::get_completion_signatures_t, _Self&&, _Env) ->
        std::execution::make_completion_signatures<
          std::__member_t<_Self, Sender>,
          _Env>;

    schedule_from_sender_t(detail::queue::task_hub_t* hub, Sender sndr)
      : hub_(hub)
      , sndr_{{}, (Sender&&)sndr} {
    }
  };

}