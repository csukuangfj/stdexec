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

#include "detail/queue.cuh"
#include "detail/sync_wait.cuh"
#include "detail/bulk.cuh"
#include "detail/common.cuh"
#include "detail/let_xxx.cuh"
#include "detail/schedule_from.cuh"
#include "detail/start_detached.cuh"
#include "detail/submit.cuh"
#include "detail/split.cuh"
#include "detail/then.cuh"
#include "detail/transfer.cuh"
#include "detail/upon_error.cuh"
#include "detail/upon_stopped.cuh"
#include "detail/when_all.cuh"

namespace example::cuda::stream {

  template <std::execution::sender Sender, std::integral Shape, class Fun>
    using bulk_sender_th = bulk_sender_t<std::__x<std::remove_cvref_t<Sender>>, Shape, std::__x<std::remove_cvref_t<Fun>>>;

  template <std::execution::sender Sender>
    using split_sender_th = split_sender_t<std::__x<std::remove_cvref_t<Sender>>>;

  template <std::execution::sender Sender, class Fun>
    using then_sender_th = then_sender_t<std::__x<std::remove_cvref_t<Sender>>, std::__x<std::remove_cvref_t<Fun>>>;

  template <std::execution::sender... Senders>
    using when_all_sender_th = when_all_sender_t<std::__x<std::decay_t<Senders>>...>;

  template <std::execution::sender Sender, class Fun>
    using upon_error_sender_th = upon_error_sender_t<std::__x<std::remove_cvref_t<Sender>>, std::__x<std::remove_cvref_t<Fun>>>;

  template <std::execution::sender Sender, class Fun>
    using upon_stopped_sender_th = upon_stopped_sender_t<std::__x<std::remove_cvref_t<Sender>>, std::__x<std::remove_cvref_t<Fun>>>;

  template <class Let, std::execution::sender Sender, class Fun>
    using let_xxx_th = let_sender_t<std::__x<std::remove_cvref_t<Sender>>, std::__x<std::remove_cvref_t<Fun>>, Let>;

  template <std::execution::sender Sender>
    using transfer_sender_th = transfer_sender_t<std::__x<Sender>>;

  struct scheduler_t {
    friend context_t;

    template <std::execution::sender Sender>
      using schedule_from_sender_th = schedule_from_sender_t<scheduler_t, std::__x<std::remove_cvref_t<Sender>>>;

    template <class R_>
      struct operation_state_t {
        using R = std::__t<R_>;
        [[no_unique_address]] R rec_;
        friend void tag_invoke(std::execution::start_t, operation_state_t& op) noexcept {
          if constexpr (stream_receiver<R>) {
            std::execution::set_value((R&&)op.rec_);
          } else {
            detail::continuation_kernel<std::decay_t<R>, std::execution::set_value_t><<<1, 1>>>(op.rec_, std::execution::set_value);
          }
        }
      };

    struct sender_t : sender_base_t {
      using completion_signatures =
        std::execution::completion_signatures<
          std::execution::set_value_t(),
          std::execution::set_error_t(cudaStream_t)>;

      template <class R>
        friend auto tag_invoke(std::execution::connect_t, sender_t, R&& rec)
          noexcept(std::is_nothrow_constructible_v<std::remove_cvref_t<R>, R>)
          -> operation_state_t<std::__x<std::remove_cvref_t<R>>> {
          return {(R&&) rec};
        }

      scheduler_t make_scheduler() const {
        return scheduler_t{hub_};
      }

      template <class CPO>
      friend scheduler_t
      tag_invoke(std::execution::get_completion_scheduler_t<CPO>, sender_t self) noexcept {
        return self.make_scheduler();
      }

      sender_t(detail::queue::task_hub_t* hub) noexcept 
        : hub_(hub) {}

      detail::queue::task_hub_t * hub_;
    };

    template <std::execution::sender S>
    friend schedule_from_sender_th<S>
    tag_invoke(std::execution::schedule_from_t, const scheduler_t& sch, S&& sndr) noexcept {
      return schedule_from_sender_th<S>(sch.hub_, (S&&) sndr);
    }

    template <std::execution::sender S, std::integral Shape, class Fn>
    friend bulk_sender_th<S, Shape, Fn>
    tag_invoke(std::execution::bulk_t, const scheduler_t& sch, S&& sndr, Shape shape, Fn fun) noexcept {
      return bulk_sender_th<S, Shape, Fn>{{}, (S&&) sndr, shape, (Fn&&)fun};
    }

    template <std::execution::sender S, class Fn>
    friend then_sender_th<S, Fn>
    tag_invoke(std::execution::then_t, const scheduler_t& sch, S&& sndr, Fn fun) noexcept {
      return then_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
    }

    template <std::__one_of<std::execution::let_value_t, std::execution::let_stopped_t, std::execution::let_error_t> Let, std::execution::sender S, class Fn>
    friend let_xxx_th<Let, S, Fn>
    tag_invoke(Let, const scheduler_t& sch, S&& sndr, Fn fun) noexcept {
      return let_xxx_th<Let, S, Fn>{{}, (S &&) sndr, (Fn &&) fun};
    }

    template <std::execution::sender S, class Fn>
    friend upon_error_sender_th<S, Fn>
    tag_invoke(std::execution::upon_error_t, const scheduler_t& sch, S&& sndr, Fn fun) noexcept {
      return upon_error_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
    }

    template <std::execution::sender S, class Fn>
    friend upon_stopped_sender_th<S, Fn>
    tag_invoke(std::execution::upon_stopped_t, const scheduler_t& sch, S&& sndr, Fn fun) noexcept {
      return upon_stopped_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
    }

    template <std::execution::sender... Senders>
    friend auto 
    tag_invoke(std::execution::transfer_when_all_t, const scheduler_t& sch, Senders&&... sndrs) noexcept {
      return std::execution::transfer(when_all_sender_th<Senders...>{(Senders&&)sndrs...}, sch);
    }

    template <std::execution::sender... Senders>
    friend auto 
    tag_invoke(std::execution::transfer_when_all_with_variant_t, const scheduler_t& sch, Senders&&... sndrs) noexcept {
      return std::execution::transfer(
          when_all_sender_th<std::tag_invoke_result_t<std::execution::__into_variant_t, Senders>...>{
            std::execution::into_variant((Senders&&)sndrs)...}, sch);
    }

    template <std::execution::sender S, std::execution::scheduler Sch>
    friend auto
    tag_invoke(std::execution::transfer_t, const scheduler_t& sch, S&& sndr, Sch&& scheduler) noexcept {
      return std::execution::schedule_from((Sch&&)scheduler, transfer_sender_th<S>(sch.hub_, (S&&)sndr));
    }

    template <std::execution::sender S>
    friend split_sender_th<S>
    tag_invoke(std::execution::split_t, const scheduler_t& sch, S&& sndr) noexcept {
      return split_sender_th<S>((S&&)sndr);
    }

    friend sender_t tag_invoke(std::execution::schedule_t, const scheduler_t& self) noexcept {
      return {self.hub_};
    }

    template <std::execution::sender S>
    friend auto
    tag_invoke(std::this_thread::sync_wait_t, const scheduler_t& self, S&& sndr) {
      return sync_wait::sync_wait_t{}(self.hub_, (S&&)sndr);
    }

    friend std::execution::forward_progress_guarantee tag_invoke(
        std::execution::get_forward_progress_guarantee_t,
        const scheduler_t&) noexcept {
      return std::execution::forward_progress_guarantee::weakly_parallel;
    }

    bool operator==(const scheduler_t&) const noexcept = default;

    scheduler_t(detail::queue::task_hub_t* hub)
      : hub_(hub) {
    }

  // private: TODO
    detail::queue::task_hub_t* hub_{};
  };

  struct context_t {
    detail::queue::task_hub_t hub{};

    scheduler_t get_scheduler() {
      return {&hub};
    }
  };

  template <stream_completing_sender Sender>
  void tag_invoke(std::execution::start_detached_t, Sender&& sndr) noexcept(false) {
    submit::submit_t{}((Sender&&)sndr, start_detached::detached_receiver_t{});
  }

  template <stream_completing_sender... Senders>
  when_all_sender_th<Senders...>
  tag_invoke(std::execution::when_all_t, Senders&&... sndrs) noexcept {
    return when_all_sender_th<Senders...>{(Senders&&)sndrs...};
  }

  template <stream_completing_sender... Senders>
  when_all_sender_th<std::tag_invoke_result_t<std::execution::__into_variant_t, Senders>...>
  tag_invoke(std::execution::when_all_with_variant_t, Senders&&... sndrs) noexcept {
    return when_all_sender_th<std::tag_invoke_result_t<std::execution::__into_variant_t, Senders>...>{
      std::execution::into_variant((Senders&&)sndrs)...
    };
  }

  template <std::execution::sender S, class Fn>
  upon_error_sender_th<S, Fn>
  tag_invoke(std::execution::upon_error_t, S&& sndr, Fn fun) noexcept {
    return upon_error_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
  }

  template <std::execution::sender S, class Fn>
  upon_stopped_sender_th<S, Fn>
  tag_invoke(std::execution::upon_stopped_t, S&& sndr, Fn fun) noexcept {
    return upon_stopped_sender_th<S, Fn>{{}, (S&&) sndr, (Fn&&)fun};
  }
}

